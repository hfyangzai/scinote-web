class SearchController < ApplicationController
  before_filter :load_vars, only: :index
  before_filter :load_markdown, only: :index

  MIN_QUERY_CHARS = 2

  def index
    if not @search_query
      redirect_to new_search_path
    end

    count_search_results

    search_projects if @search_category == :projects
    search_workflows if @search_category == :workflows
    search_modules if @search_category == :modules
    search_results if @search_category == :results
    search_tags if @search_category == :tags
    search_reports if @search_category == :reports
    search_protocols if @search_category == :protocols
    search_steps if @search_category == :steps
    search_checklists if @search_category == :checklists
    search_samples if @search_category == :samples
    search_assets if @search_category == :assets
    search_tables if @search_category == :tables
    search_comments if @search_category == :comments

    @search_pages = (@search_count.to_f / SEARCH_LIMIT.to_f).ceil
    @start_page = @search_page - 2
    @start_page = 1 if @start_page < 1
    @end_page = @start_page + 4

    if @end_page > @search_pages
      @end_page = @search_pages
      @start_page = @end_page - 4
      @start_page = 1 if @start_page < 1
    end
  end

  def new
  end

  private

  def load_vars
    @search_query = params[:q] || ''
    @search_category = params[:category] || ''
    @search_category = @search_category.to_sym
    @search_page = params[:page].to_i || 1

    error = false
    @search_query.split().each do |w|
      if w.length < MIN_QUERY_CHARS
        error = true
      end
    end

    if error
      flash[:error] = t'search.index.error.query_length', n: MIN_QUERY_CHARS
      redirect_to :back
    end
    if @search_page < 1
      @search_page = 1
    end
  end
# Initialize markdown parser
  def load_markdown
    if @search_category == :results
      @markdown = Redcarpet::Markdown.new(
        Redcarpet::Render::HTML.new(
          filter_html: true,
          no_images: true
        )
      )
    end
  end

  protected

  def search_by_name(model)
    model.search(current_user, true, @search_query, @search_page)
  end

  def count_by_name(model)
    search_by_name(model).limit(nil).offset(nil).size
  end

  def count_search_results
    @project_search_count = count_by_name Project
    @workflow_search_count = count_by_name MyModuleGroup
    @module_search_count = count_by_name MyModule
    @result_search_count = count_by_name Result
    @tag_search_count = count_by_name Tag
    @report_search_count = count_by_name Report
    @protocol_search_count = count_by_name Protocol
    @step_search_count = count_by_name Step
    @checklist_search_count = count_by_name Checklist
    @sample_search_count = count_by_name Sample
    @asset_search_count = count_by_name Asset
    @table_search_count = count_by_name Table
    @comment_search_count = count_by_name Comment

    @search_results_count = @project_search_count
    @search_results_count += @workflow_search_count
    @search_results_count += @module_search_count
    @search_results_count += @result_search_count
    @search_results_count += @tag_search_count
    @search_results_count += @report_search_count
    @search_results_count += @protocol_search_count
    @search_results_count += @step_search_count
    @search_results_count += @checklist_search_count
    @search_results_count += @sample_search_count
    @search_results_count += @asset_search_count
    @search_results_count += @table_search_count
    @search_results_count += @comment_search_count
  end

  def search_projects
    @project_results = []
    if @project_search_count > 0 then
      @project_results = search_by_name Project
    end
    @search_count = @project_search_count
  end

  def search_workflows
    @workflow_results = []
    if @workflow_search_count > 0 then
      @workflow_results = search_by_name MyModuleGroup
    end
    @search_count = @workflow_search_count
  end

  def search_modules
    @module_results = []
    if @module_search_count > 0 then
      @module_results = search_by_name MyModule
    end
    @search_count = @module_search_count
  end

  def search_results
    @result_results = []
    if @result_search_count > 0 then
      @result_results = search_by_name Result
    end
    @search_count = @result_search_count
  end

  def search_tags
    @tag_results = []
    if @tag_search_count > 0 then
      @tag_results = search_by_name Tag
    end
    @search_count = @tag_search_count
  end

  def search_reports
    @report_results = []
    if @report_search_count > 0 then
      @report_results = search_by_name Report
    end
    @search_count = @report_search_count
  end

  def search_protocols
    @protocol_results = []
    if @protocol_search_count > 0 then
      @protocol_results = search_by_name Protocol
    end
    @search_count = @protocol_search_count
  end

  def search_steps
    @step_results = []
    if @step_search_count > 0 then
      @step_results = search_by_name Step
    end
    @search_count = @step_search_count
  end

  def search_checklists
    @checklist_results = []
    if @checklist_search_count > 0 then
      @checklist_results = search_by_name Checklist
    end
    @search_count = @checklist_search_count
  end

  def search_samples
    @sample_results = []
    if @sample_search_count > 0 then
      @sample_results = search_by_name Sample
    end
    @search_count = @sample_search_count
  end

  def search_assets
    @asset_results = []
    if @asset_search_count > 0 then
      @asset_results = search_by_name Asset
    end
    @search_count = @asset_search_count
  end

  def search_tables
    @table_results = []
    if @table_search_count > 0 then
      @table_results = search_by_name Table
    end
    @search_count = @table_search_count
  end

  def search_comments
    @comment_results = []
    if @comment_search_count > 0 then
      @comment_results = search_by_name Comment
    end
    @search_count = @comment_search_count
  end
end
