class Experiment < ActiveRecord::Base
  include ArchivableModel, SearchableModel

  belongs_to :project, inverse_of: :experiments
  belongs_to :created_by, foreign_key: :created_by_id, class_name: 'User'
  belongs_to :last_modified_by, foreign_key: :last_modified_by_id, class_name: 'User'
  belongs_to :archived_by, foreign_key: :archived_by_id, class_name: 'User'
  belongs_to :restored_by, foreign_key: :restored_by_id, class_name: 'User'

  has_many :my_modules, inverse_of: :experiment, dependent: :destroy
  has_many :my_module_groups, inverse_of: :experiment, dependent: :destroy

  validates :name,
            presence: true,
            length: { minimum: 4, maximum: 50 },
            uniqueness: { scope: :project, case_sensitive: false }
  validates :description, length: { maximum: 255 }
  validates :project, presence: true
  validates :created_by, presence: true
  validates :last_modified_by, presence: true
  with_options if: :archived do |experiment|
    experiment.validates :archived_by, presence: true
    experiment.validates :archived_on, presence: true
  end

  scope :is_archived, ->(is_archived) { where("archived = ?", is_archived) }

  def self.search(user, include_archived, query = nil, page = 1)
    project_ids =
      Project
        .search(user, include_archived, nil, SHOW_ALL_RESULTS)
        .select("id")

    if query
      a_query = query.strip
      .gsub("_","\\_")
      .gsub("%","\\%")
      .split(/\s+/)
      .map {|t|  "%" + t + "%" }
    else
      a_query = query
    end

    if include_archived
      new_query =
        Experiment
          .where(project: project_ids)
          .where_attributes_like([:name, :description], a_query)
    else
      new_query =
        Experiment
          .is_archived(false)
          .where(project: project_ids)
          .where_attributes_like([:name, :description], a_query)
    end

    # Show all results if needed
    if page == SHOW_ALL_RESULTS
      new_query
    else
      new_query
      .limit(SEARCH_LIMIT)
      .offset((page - 1) * SEARCH_LIMIT)
    end
  end

  def modules_without_group
    MyModule.where(experiment_id: id).where(my_module_group: nil)
      .where(archived: false)
  end

  def active_module_groups
    self.my_module_groups.joins(:my_modules)
        .where('my_modules.archived = ?', false)
        .distinct
  end

  def assigned_modules(user)
    role = self.project.user_role(user)
    if role.blank?
      return MyModule.none
    elsif role == "owner"
      return self.active_modules
    else
      return self.active_modules
        .joins(:user_my_modules)
        .where("user_my_modules.user_id IN (?)", user.id)
        .distinct
    end
  end

  def active_modules
    my_modules.where(:archived => false)
  end

  def archived_modules
    my_modules.where(:archived => true)
  end

  def assigned_samples
    Sample.joins(:my_modules).where(my_modules: {id: my_modules} )
  end

  def unassigned_samples(assigned_samples)
    Sample.where(organization_id: organization).where.not(id: assigned_samples)
  end

  def update_canvas(
    to_archive,
    to_add,
    to_rename,
    to_clone,
    connections,
    positions,
    current_user,
    module_groups
  )
    cloned_modules = []
    begin
      Experiment.transaction do
        # First, add new modules
        new_ids, cloned_pairs, originals = add_modules(
          to_add, to_clone, current_user)
        cloned_modules = cloned_pairs.collect { |mn, _| mn }

        # Rename modules
        rename_modules(to_rename)

        # Add activities that modules were created
        originals.each do |m|
          Activity.create(
            type_of: :create_module,
            user: current_user,
            project: selfproject,
            my_module: m,
            message: I18n.t(
              "activities.create_module",
              user: current_user.full_name,
              module: m.name
            )
          )
        end

        # Add activities that modules were cloned
        cloned_pairs.each do |mn, mo|
          Activity.create(
            type_of: :clone_module,
            project: mn.experiment.project,
            my_module: mn,
            user: current_user,
            message: I18n.t(
              "activities.clone_module",
              user: current_user.full_name,
              module_new: mn.name,
              module_original: mo.name
            )
          )
        end

        # Then, archive modules that need to be archived
        archive_modules(to_archive, current_user)

        # Update connections, positions & module group variables
        # with actual IDs retrieved from the new modules creation
        updated_connections = []
        connections.each do |a,b|
          updated_connections << [new_ids.fetch(a, a), new_ids.fetch(b, b)]
        end
        updated_positions = Hash.new
        positions.each do |id, pos|
          updated_positions[new_ids.fetch(id, id)] = pos
        end
        updated_module_groups = {}
        module_groups.each do |id, name|
          updated_module_groups[new_ids.fetch(id, id)] = name
        end

        # Update connections
        update_module_connections(updated_connections)

        # Update module positions (no validation needed here)
        update_module_positions(updated_positions)

        # Normalize module positions
        normalize_module_positions

        # Finally, update module groups
        update_module_groups(updated_module_groups, current_user)
      end
    rescue ActiveRecord::ActiveRecordError, ArgumentError, ActiveRecord::RecordNotSaved
      return false
    end

    return true
  end

  private

  # Archive all modules. Receives an array of module integer IDs.
  def archive_modules(module_ids)
    module_ids.each do |m_id|
      my_module = self.my_modules.find_by_id(m_id)
      unless my_module.blank?
        my_module.archive!
      end
    end
    modules.reload
  end

   # Archive all modules. Receives an array of module integer IDs and current user.
  def archive_modules(module_ids, current_user)
    module_ids.each do |m_id|
      my_module = self.my_modules.find_by_id(m_id)
      unless my_module.blank?
        my_module.archive!(current_user)
      end
    end
    my_modules.reload
  end

  # Add modules, and returns a map of "virtual" IDs with
  # actual IDs of saved modules.
  # to_add is an array of hashes, each containing 'name',
  # 'x', 'y' and 'id'.
  # to_clone is a hash, storing new cloned modules as keys,
  # and original modules as values.
  def add_modules(to_add, to_clone, current_user)
    originals = []
    cloned_pairs = {}
    ids_map = Hash.new
    to_add.each do |m|
      original = MyModule.find_by_id(to_clone.fetch(m[:id], nil))
      if original.present? then
        my_module = original.deep_clone(current_user)
        cloned_pairs[my_module] = original
      else
        my_module = MyModule.new(
          experiment: self)
        originals << my_module
      end

      my_module.name = m[:name]
      my_module.x = m[:x]
      my_module.y = m[:y]
      my_module.created_by = current_user
      my_module.last_modified_by = current_user
      my_module.save!

      ids_map[m[:id]] = my_module.id.to_s
    end
    my_modules.reload
    return ids_map, cloned_pairs, originals
  end

  # Rename modules; this method accepts a map where keys
  # represent IDs of modules, and values new names for
  # such modules. If a module with given ID doesn't exist,
  # it's obviously not updated.
  def rename_modules(to_rename)
    to_rename.each do |id, new_name|
      my_module = MyModule.find_by_id(id)
      if my_module.present?
        my_module.name = new_name
        my_module.save!
      end
    end
  end

  # Update connections for all modules in this project.
  # Input is an array of arrays, where first element represents
  # source node, and second element represents target node.
  # Example input: [ [1, 2], [2, 3], [4, 5], [2, 5] ]
  def update_module_connections(connections)
    require 'rgl/base'
    require 'rgl/adjacency'
    require 'rgl/topsort'

    dg = RGL::DirectedAdjacencyGraph.new
    connections.each do |a,b|
      # Check if both vertices exist
      if (my_modules.find_all {|m| [a.to_i, b.to_i].include? m.id }).count == 2
        dg.add_edge(a, b)
      end
    end

    # Check if cycles exist!
    topsort = dg.topsort_iterator.to_a
    if topsort.length == 0 and dg.edges.size > 1
      raise ArgumentError, "Cycles exist."
    end

    # First, delete existing connections
    # but keep a copy of previous state
    previous_sources = {}
    previous_sources.default = []
    my_modules.each do |m|
      previous_sources[m.id] = []
      m.inputs.each do |c|
        previous_sources[m.id] << c.from
      end
    end
    self.my_modules.each do |m|
      unless m.outputs.destroy_all
        raise ActiveRecord::ActiveRecordError
      end
    end


    # Add new connections
    filtered_edges = dg.edges.collect { |e| [e.source, e.target] }
    filtered_edges.each do |a, b|
      Connection.create!(:input_id => b, :output_id => a)
    end

    # Unassign samples from former downstream modules
    # for all destroyed connections
    unassign_samples_from_old_downstream_modules(previous_sources)

    visited = []
    # Assign samples to all new downstream modules
    filtered_edges.each do |a, b|
      source = self.my_modules.find(a.to_i)
      target = self.my_modules.find(b.to_i)
      # Do this only for new edges
      if previous_sources[target.id].exclude?(source)
        # Go as high upstream as new edges take us
        # and then assign samples to all downsteam samples
        assign_samples_to_new_downstream_modules(previous_sources, visited, source)
      end
    end

    # Save topological order of modules (for modules without workflow,
    # leave them unordered)
    self.my_modules.each do |m|
      if topsort.include? m.id.to_s
        m.workflow_order = topsort.find_index(m.id.to_s)
      else
        m.workflow_order = -1
      end
      m.save!
    end

    # Make sure to reload my modules, which now have updated connections and samples
    self.my_modules.reload
    true
  end

  # When connections are deleted, unassign samples that
  # are not inherited anymore
  def unassign_samples_from_old_downstream_modules(sources)
    self.my_modules.each do |my_module|
      sources[my_module.id].each do |s|
        # Only do this for newly deleted connections
        if s.outputs.map{|i| i.to}.exclude? my_module
          my_module.get_downstream_modules.each do |dm|
            # Get unique samples for all upstream modules
            um = dm.get_upstream_modules
            um.shift  # remove current module
            ums = um.map{|m| m.samples}.flatten.uniq
            s.samples.each do |sample|
              dm.samples.delete(sample) if ums.exclude? sample
            end
          end
        end
      end
    end
  end

  # Assign samples to new connections recursively
  def assign_samples_to_new_downstream_modules(sources, visited, my_module)
    # If samples are already assigned for this module, stop going upstream
    if visited.include? (my_module)
      return
    end
    visited << my_module
    # Edge case, when module is source or it doesn't have any new input connections
    if my_module.inputs.blank? or (
                                    my_module.inputs.map{|c| c.from} -
                                    sources[my_module.id]
                                  ).empty?
      my_module.get_downstream_modules.each do |dm|
        new_samples = my_module.samples.select { |el| dm.samples.exclude?(el) }
        dm.samples.push(*new_samples)
      end
    else
      my_module.inputs.each do |input|
        # Go upstream for new in connections
        if sources[my_module.id].exclude?(input.from)
          assign_samples_to_new_downstream_modules(input.from)
        end
      end
    end
  end

  # Updates positions of modules.
  # Input is a map where keys are module IDs, and values are
  # hashes like { x: <x>, y: <y> }.
  def update_module_positions(positions)
    positions.each do |id, pos|
      unless MyModule.update(id, x: pos[:x], y: pos[:y])
        raise ActiveRecord::ActiveRecordError
      end
    end
    self.my_modules.reload
  end

  # Normalize module positions in this project.
  def normalize_module_positions
    # This method normalizes module positions so x-s and y-s
    # are all positive
    x_diff = (self.my_modules.collect { |m| m.x }).min
    y_diff = (self.my_modules.collect { |m| m.y }).min

    self.my_modules.each do |m|
      unless
        m.update_attribute(:x, m.x - x_diff) and
          m.update_attribute(:y, m.y - y_diff)
        raise ActiveRecord::ActiveRecordError
      end
    end
  end

  # Recalculate module groups in this project. Input is
  # a hash of module ids and their corresponding module names.
  def update_module_groups(module_groups, current_user)
    require 'rgl/base'
    require 'rgl/adjacency'
    require 'rgl/connected_components'

    dg = RGL::DirectedAdjacencyGraph[]
    group_ids = Set.new
    active_modules.each do |m|
      unless m.my_module_group.blank?
        group_ids << m.my_module_group.id
      end
      unless dg.has_vertex? m.id
        dg.add_vertex m.id
      end
      m.outputs.each do |o|
        dg.add_edge m.id, o.to.id
      end
    end
    workflows = []
    dg.to_undirected.each_connected_component { |w| workflows <<  w }

    # Retrieve maximum allowed module group name
    max_length = (MyModuleGroup.validators_on(:name).select { |v| v.class == ActiveModel::Validations::LengthValidator }).first.options[:maximum]
    # For each workflow, generate new names
    new_index = 1
    wf_names = []
    suffix = I18n.t("my_module_groups.new.suffix")
    cut_index = -(suffix.length + 1)
    workflows.each do |w|
      modules = MyModule.find(w)

      # Get an array of module names
      names = []
      modules.each do |m|
        names << module_groups.fetch(m.id.to_s, "")
      end
      names = names.uniq
      name = (names.select { |v| v != "" }).join(", ")

      if w.length <= 1
        name = nil
      elsif name.blank?
        name = I18n.t("my_module_groups.new.name", index: new_index)
        new_index += 1
        while MyModuleGroup.find_by(name: name).present?
          name = I18n.t("my_module_groups.new.name", index: new_index)
          new_index += 1
        end
      elsif name.length > max_length
        # If length is too long, shorten it
        name = name[0..(max_length + cut_index)] + suffix
      end

      wf_names << name
    end

    # Remove any existing module groups from modules
    unless MyModuleGroup.destroy_all(:id => group_ids.to_a)
      raise ActiveRecord::ActiveRecordError
    end

    # Second, create new groups
    workflows.each_with_index do |w, i|
      # Single modules are not considered part of any workflow
      if w.length > 1
        group = MyModuleGroup.new(
          name: wf_names[i],
          project: self,
          my_modules: MyModule.find(w))
        group.created_by = current_user
        group.save!
      end
    end

    my_module_groups.reload
    true
  end
end