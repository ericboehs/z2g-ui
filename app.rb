require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'sinatra'
  gem 'graphql-client'
  gem 'puma'
  gem 'pry'
  gem 'rack'
  gem 'rackup'
  gem 'uri'
  gem 'rerun'
end


require 'sinatra/base'
require 'graphql/client'
require 'graphql/client/http'
require 'uri'
require 'net/http'
require 'json'

class App < Sinatra::Base
  set :server, :puma
  set :inline_templates, true
  
  # Class-level cache for API responses
  @@zenhub_cache = {}
  @@github_cache = {}
  
  # Cache expiration time (1 hour)
  CACHE_EXPIRY = 3600

  if ENV['ZENHUB_TOKEN']
    # GraphQL client setup
    HTTP = GraphQL::Client::HTTP.new('https://api.zenhub.com/public/graphql') do
      def headers(context)
        { "Authorization": "Bearer #{ENV['ZENHUB_TOKEN']}" }
      end
    end

    Schema = GraphQL::Client.load_schema(HTTP)
    Client = GraphQL::Client.new(schema: Schema, execute: HTTP)

    # GraphQL query definition
    PipelinesQuery = Client.parse <<~'GRAPHQL'
      query($workspaceId: ID!) {
        workspace(id: $workspaceId) {
          id
          displayName
          repositoriesConnection {
            nodes {
              ghId
              id
              name
            }
          }
          repositories {
            id
            ghId
            name
            owner {
              id
              ghId
              login
              avatarUrl
            }
          }
          pipelines(includeClosed: false) {
            id
            name
            isDefaultPRPipeline
            isEpicPipeline
          }
          priorities {
            id
            name
            color
          }
        }
      }
    GRAPHQL

    WorkspaceSprintsQuery = Client.parse <<~'GRAPHQL'
      query($workspaceId: ID!) {
        workspace(id: $workspaceId) {
          id
          sprints {
            nodes {
              id
              name
              startAt
              endAt
              state
            }
          }
        }
      }
    GRAPHQL

    PipelineIssuesQuery = Client.parse <<~'GRAPHQL'
      query($pipelineId: ID!, $query: String, $issuesAfter: String, $numberOfIssues: Int!, $filters: IssueSearchFiltersInput!, $order: IssueOrderInput) {
        searchIssuesByPipeline(
          pipelineId: $pipelineId
          query: $query
          filters: $filters
          order: $order
          after: $issuesAfter
          first: $numberOfIssues
        ) {
          pageInfo {
            endCursor
            startCursor
            hasNextPage
          }
          pipelineCounts {
            issuesCount
            pullRequestsCount
            sumEstimates
            unfilteredIssueCount
            unfilteredSumEstimates
          }
          nodes {
            id
            number
            title
            state
            htmlUrl
            type
            viewerPermission
            estimate {
              value
            }
            sprints {
              totalCount
              nodes {
                id
                name
                startAt
              }
            }
          }
        }
      }
    GRAPHQL
  end

  helpers do
    def extract_github_project_info(url)
      return nil unless url
      
      # Handle both formats:
      # https://github.com/orgs/owner/projects/1
      # https://github.com/owner/projects/1
      if matches = url.match(%r{github\.com/(?:orgs/)?([^/]+)/projects/(\d+)})
        {
          organization: matches[1],
          project_number: matches[2].to_i
        }
      end
    end

    def extract_workspace_id(url)
      return nil unless url

      parts = url.strip.split('/')
      workspace_part = parts.find { |part| part.match?(/[0-9a-f]{24}/) }
      workspace_part.match(/([0-9a-f]{24})/)[1] if workspace_part
    end

    def fetch_pipeline_issues(workspace_id, pipeline_id, repository_ids)
      Client.query(
        PipelineIssuesQuery,
        variables: {
          pipelineId: pipeline_id,
          numberOfIssues: 100,
          filters: {
            matchType: "all",
            repositoryIds: repository_ids
          },
        }
      )
    end

    def query_zenhub_workspace(workspace_id)
      cache_key = workspace_id
      
      # Check cache
      if cached = @@zenhub_cache[cache_key]
        if Time.now.to_i - cached[:timestamp] < CACHE_EXPIRY
          @workspace = cached[:workspace]
          @pipeline_data = cached[:pipeline_data]
          @sprints = cached[:sprints]
          return
        else
          @@zenhub_cache.delete(cache_key)
        end
      end
      
      # Query ZenHub
      result = Client.query(PipelinesQuery, variables: { workspaceId: workspace_id })
      @workspace = result.data.workspace if result.data

      # Fetch issue counts for each pipeline
      if @workspace
        repository_ids = @workspace.repositories.map(&:id)
        @pipeline_data = {}
        @workspace.pipelines.each do |pipeline|
          issues_result = fetch_pipeline_issues(workspace_id, pipeline.id, repository_ids)
          issues = issues_result.data.search_issues_by_pipeline.nodes
          @pipeline_data[pipeline.id] = {
            count: issues_result.data.search_issues_by_pipeline.pipeline_counts.issues_count,
            issues: issues
          }
        end

        # Get sprints directly from workspace
        @sprints = query_workspace_sprints(workspace_id)

        # Cache the results
        @@zenhub_cache[cache_key] = {
          workspace: @workspace,
          pipeline_data: @pipeline_data,
          sprints: @sprints,
          timestamp: Time.now.to_i
        }
      end
    end

    def query_workspace_sprints(workspace_id)
      result = Client.query(WorkspaceSprintsQuery, variables: { workspaceId: workspace_id })
      result.data.workspace.sprints.nodes if result.data&.workspace
    end

    def query_github_project(github_info)
      cache_key = "#{github_info[:organization]}/#{github_info[:project_number]}"
      
      # Check cache
      if cached = @@github_cache[cache_key]
        if Time.now.to_i - cached[:timestamp] < CACHE_EXPIRY
          @github_project_id = cached[:project_id]
          @github_status_options = cached[:status_options]
          @github_status_field = cached[:status_field]
          @github_sprint_field = cached[:sprint_field]
          return
        else
          @@github_cache.delete(cache_key)
        end
      end
      
      # Query GitHub GraphQL API
      github_query = <<~GRAPHQL
        query {
          organization(login: "#{github_info[:organization]}") {
            projectV2(number: #{github_info[:project_number]}) {
              id
            }
          }
        }
      GRAPHQL

      uri = URI('https://api.github.com/graphql')
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      
      request = Net::HTTP::Post.new(uri)
      request['Authorization'] = "Bearer #{ENV['GITHUB_TOKEN']}"
      request['Content-Type'] = 'application/json'
      request.body = { query: github_query }.to_json

      response = http.request(request)
      if response.is_a?(Net::HTTPSuccess)
        github_data = JSON.parse(response.body)
        @github_project_id = github_data.dig('data', 'organization', 'projectV2', 'id')
        
        # Query for status columns
        status_query = <<~GRAPHQL
          query {
            node(id: "#{@github_project_id}") {
              ... on ProjectV2 {
                statusField: field(name: "Status") {
                  ... on ProjectV2SingleSelectField {
                    id
                    name
                    options {
                      id
                      name
                    }
                  }
                }
                sprintField: field(name: "Sprint") {
                  ... on ProjectV2IterationField {
                    databaseId
                    id
                    name
                    configuration {
                      iterations {
                        id
                        title
                        duration
                        startDate
                        duration
                      }
                      completedIterations {
                        id
                        title
                        duration
                        startDate
                        duration
                      }
                    }
                  }
                }
              }
            }
          }
        GRAPHQL

        status_request = Net::HTTP::Post.new(uri)
        status_request['Authorization'] = "Bearer #{ENV['GITHUB_TOKEN']}"
        status_request['Content-Type'] = 'application/json'
        status_request.body = { query: status_query }.to_json

        status_response = http.request(status_request)
        if status_response.is_a?(Net::HTTPSuccess)
          status_data = JSON.parse(status_response.body)
          @github_status_options = status_data.dig('data', 'node', 'statusField', 'options')
          @github_sprint_field = status_data.dig('data', 'node', 'sprintField')
          @github_status_field = status_data.dig('data', 'node', 'statusField')
        end
      end
    end
  end

  get '/' do
    redirect '/sprints'
  end

  get '/sprints' do
    workspace_id = extract_workspace_id(params[:workspace_url])
    github_info = extract_github_project_info(params[:github_url])
    
    if workspace_id.nil? || github_info.nil?
      erb :setup
    else
      query_zenhub_workspace(workspace_id)
      query_github_project(github_info)

      erb :sprints
    end
  end

  get '/clear-cache' do
    @@zenhub_cache.clear
    @@github_cache.clear
    redirect back
  end

  get '/pipelines' do
    workspace_id = extract_workspace_id(params[:workspace_url])
    github_info = extract_github_project_info(params[:github_url])
    
    if workspace_id.nil?
      status 400
      return "Could not extract workspace ID from URL. Please ensure you're using a valid ZenHub workspace URL."
    end

    if github_info.nil?
      status 400
      return "Could not extract GitHub project info. Please ensure you're using a valid GitHub project URL."
    end

    query_zenhub_workspace(workspace_id)
    query_github_project(github_info)

    erb :pipelines
  end
end

App.run! if __FILE__ == $0

__END__

@@sprints
<div class="min-h-full flex flex-col justify-center py-12 sm:px-6 lg:px-8">
  <% if @workspace %>
    <div class="sm:mx-auto sm:w-full sm:max-w-4xl">
      <div class="flex justify-between items-center mb-6">
        <h2 class="text-2xl font-bold"><%= @workspace.display_name %></h2>
        <div class="flex gap-4">
          <a href="/sprints?<%= request.query_string %>" class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md text-white bg-indigo-600 hover:bg-indigo-700">
            Sprints
          </a>
          <a href="/pipelines?<%= request.query_string %>" class="inline-flex items-center px-4 py-2 border border-gray-300 text-sm font-medium rounded-md text-gray-700 bg-white hover:bg-gray-50">
            Pipelines
          </a>
          <a href="/clear-cache" class="inline-flex items-center px-4 py-2 border border-gray-300 text-sm font-medium rounded-md text-gray-700 bg-white hover:bg-gray-50">
            <svg class="w-4 h-4 mr-1" viewBox="0 0 24 24" fill="none" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
            </svg>
            Refresh
          </a>
        </div>
      </div>
      <div class="flex justify-between items-center mb-4">
        <div class="flex gap-4 text-sm text-gray-600">
          <a href="<%= params[:workspace_url] %>" target="_blank" class="hover:text-gray-900 flex items-center gap-1">
            <svg class="w-4 h-4" viewBox="0 0 24 24" fill="currentColor">
              <path d="M10 6V8H5V19H16V14H18V20C18 20.5523 17.5523 21 17 21H4C3.44772 21 3 20.5523 3 20V7C3 6.44772 3.44772 6 4 6H10ZM21 3V11H19L18.9999 6.413L11.2071 14.2071L9.79289 12.7929L17.5849 5H13V3H21Z"/>
            </svg>
            ZenHub Workspace
          </a>
          <a href="<%= params[:github_url] %>" target="_blank" class="hover:text-gray-900 flex items-center gap-1">
            <svg class="w-4 h-4" viewBox="0 0 24 24" fill="currentColor">
              <path d="M10 6V8H5V19H16V14H18V20C18 20.5523 17.5523 21 17 21H4C3.44772 21 3 20.5523 3 20V7C3 6.44772 3.44772 6 4 6H10ZM21 3V11H19L18.9999 6.413L11.2071 14.2071L9.79289 12.7929L17.5849 5H13V3H21Z"/>
            </svg>
            GitHub Project
          </a>
        </div>
      </div>
      <% if @sprints.any? %>
        <div class="mb-6">
          <div class="flex justify-between items-center mb-2">
            <h3 class="text-lg font-medium text-gray-900">Sprint Mapping</h3>
            <div id="selected-issues-json" class="fixed bottom-0 left-0 right-0 bg-gray-100 border-t border-gray-200 p-4 shadow-lg max-h-[30vh] overflow-y-auto hidden">
              <div class="max-w-4xl mx-auto">
                <h4 class="text-sm font-medium text-gray-900 mb-2">Selected Issues</h4>
              </div>
            </div>
            <a href="<%= params[:github_url] %>/settings/fields/<%= @github_sprint_field.dig('databaseId') %>" 
               target="_blank" 
               class="text-sm text-gray-600 hover:text-gray-900 flex items-center gap-1">
              <svg class="w-4 h-4" viewBox="0 0 24 24" fill="currentColor">
                <path d="M10 6V8H5V19H16V14H18V20C18 20.5523 17.5523 21 17 21H4C3.44772 21 3 20.5523 3 20V7C3 6.44772 3.44772 6 4 6H10ZM21 3V11H19L18.9999 6.413L11.2071 14.2071L9.79289 12.7929L17.5849 5H13V3H21Z"/>
              </svg>
              Need to add a Sprint?
            </a>
          </div>
          <div class="overflow-hidden shadow ring-1 ring-black ring-opacity-5 sm:rounded-lg">
            <table class="min-w-full divide-y divide-gray-300">
              <thead class="bg-gray-50">
                <tr>
                  <th scope="col" class="py-3.5 pl-4 pr-3 text-left text-sm font-semibold text-gray-900">ZenHub Sprint</th>
                  <th scope="col" class="px-3 py-3.5 text-center text-sm font-semibold text-gray-900">GitHub Sprint</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-200 bg-white">
                  <%
                    sorted_sprints = @sprints.sort_by { |sprint| -Date.parse(sprint.start_at).to_time.to_i }
                    sorted_sprints.each do |sprint|
                      # Find all issues where this is their latest sprint
                      sprint_issues = @pipeline_data.values.flat_map { |data| 
                        data[:issues].select { |issue| 
                          latest_sprint = issue.sprints.nodes.max_by { |s| Date.parse(s.start_at) }
                          latest_sprint&.id == sprint.id
                        }
                      }
                      next if sprint_issues.empty? # Skip sprints with no issues
                  %>
                  <tr class="hover:bg-gray-50">
                    <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm">
                      <div class="flex items-center justify-between">
                        <div class="flex items-center">
                          <input type="checkbox" 
                                 class="sprint-checkbox mr-2"
                                 data-sprint-name="<%= sprint.name %>"
                                 onclick="handleSprintCheckbox(this)">
                          <div class="cursor-pointer flex items-center" onclick="toggleAccordion('<%= sprint.name %>')">
                            <span class="font-medium text-gray-900"><%= sprint.name %></span>
                            <span class="text-gray-500 ml-2">(<%= sprint_issues.length %> issues)</span>
                          </div>
                        </div>
                        <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-4">
                          <path stroke-linecap="round" stroke-linejoin="round" d="M13.5 4.5 21 12m0 0-7.5 7.5M21 12H3" />
                        </svg>
                      </div>
                    </td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-right">
                      <select class="block w-full max-w-xs ml-auto rounded-md border-0 py-1.5 text-gray-900 shadow-sm ring-1 ring-inset ring-gray-300 focus:ring-2 focus:ring-inset focus:ring-indigo-600 sm:text-sm sm:leading-6" onclick="event.stopPropagation()">
                        <option value="">None</option>
                        <% 
                          all_iterations = (@github_sprint_field&.dig('configuration', 'iterations') || []) +
                                         (@github_sprint_field&.dig('configuration', 'completedIterations') || [])
                          all_iterations = all_iterations.sort_by { |i| Date.parse(i['startDate']) }
                          all_iterations.each do |iteration| 
                        %>
                          <% 
                            matching_sprint = @pipeline_data.values.flat_map { |data| 
                              data[:issues].flat_map { |issue| 
                                issue.sprints.nodes
                              }
                            }.find { |zh_sprint| 
                              zh_sprint.name == sprint.name && 
                              zh_sprint.start_at && 
                              (Date.parse(zh_sprint.start_at) - Date.parse(iteration['startDate'])).abs <= 1
                            }
                          %>
                          <%
                            start_date = Date.parse(iteration['startDate'])
                            end_date = start_date + iteration['duration'].to_i - 2
                            date_range = "#{start_date.strftime('%b %-d')} - #{end_date.strftime('%b %-d, %Y')}"
                          %>
                          <option value="<%= iteration['id'] %>" <%= 'selected' if matching_sprint %>>
                            <%= iteration['title'] %> (<%= date_range %>)
                          </option>
                        <% end %>
                      </select>
                    </td>
                  </tr>
                  <tr id="content-<%= sprint.name %>" class="hidden">
                    <td colspan="2" class="px-0 border-t border-gray-200">
                      <div class="overflow-x-auto">
                        <table class="min-w-full divide-y divide-gray-300">
                          <thead class="bg-gray-50">
                            <tr>
                              <th scope="col" class="py-3.5 pl-4 pr-3 text-left text-sm font-semibold text-gray-900 pl-8">Issue</th>
                              <th scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Pipeline</th>
                              <th scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Title</th>
                              <th scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Points</th>
                            </tr>
                          </thead>
                          <tbody class="divide-y divide-gray-200 bg-white pl-8">
                            <% sprint_issues.each do |issue| %>
                              <tr class="issue-row" data-sprint-name="<%= sprint.name %>">
                                <td class="whitespace-nowrap py-4 pl-8 pr-3 text-sm">
                                  <input type="checkbox" 
                                         class="issue-checkbox mr-2"
                                         data-issue-number="<%= issue.number %>"
                                         data-sprint-name="<%= sprint.name %>"
                                         onclick="handleIssueCheckbox(this)">
                                  <a href="<%= issue.html_url %>" target="_blank" class="text-blue-600 hover:text-blue-800">
                                    #<%= issue.number %>
                                  </a>
                                </td>
                                <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">
                                  <% pipeline = @workspace.pipelines.find { |p| @pipeline_data[p.id][:issues].include?(issue) } %>
                                  <%= pipeline&.name %>
                                </td>
                                <td class="whitespace-normal px-3 py-4 text-sm text-gray-700">
                                  <%= issue.title %>
                                </td>
                                <td class="whitespace-nowrap px-3 py-4 text-sm">
                                  <% if issue.estimate&.value %>
                                    <span class="inline-flex items-center rounded-md bg-gray-100 px-2 py-1 text-xs font-medium text-gray-600">
                                      <%= issue.estimate.value.round %> points
                                    </span>
                                  <% end %>
                                </td>
                              </tr>
                            <% end %>
                          </tbody>
                        </table>
                      </div>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      <% end %>
    </div>
  <% end %>
</div>

@@pipelines
<div class="min-h-full flex flex-col justify-center py-12 sm:px-6 lg:px-8">
  <% if @workspace %>
    <div class="sm:mx-auto sm:w-full sm:max-w-4xl">
      <div class="flex justify-between items-center mb-6">
        <h2 class="text-2xl font-bold"><%= @workspace.display_name %></h2>
        <div class="flex gap-4">
          <a href="/sprints?<%= request.query_string %>" class="inline-flex items-center px-4 py-2 border border-gray-300 text-sm font-medium rounded-md text-gray-700 bg-white hover:bg-gray-50">
            Sprints
          </a>
          <a href="/pipelines?<%= request.query_string %>" class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md text-white bg-indigo-600 hover:bg-indigo-700">
            Pipelines
          </a>
          <a href="/clear-cache" class="inline-flex items-center px-4 py-2 border border-gray-300 text-sm font-medium rounded-md text-gray-700 bg-white hover:bg-gray-50">
            <svg class="w-4 h-4 mr-1" viewBox="0 0 24 24" fill="none" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
            </svg>
            Refresh
          </a>
        </div>
      </div>
      <div class="flex justify-between items-center mb-4">
        <div class="flex gap-4 text-sm text-gray-600">
          <a href="<%= params[:workspace_url] %>" target="_blank" class="hover:text-gray-900 flex items-center gap-1">
            <svg class="w-4 h-4" viewBox="0 0 24 24" fill="currentColor">
              <path d="M10 6V8H5V19H16V14H18V20C18 20.5523 17.5523 21 17 21H4C3.44772 21 3 20.5523 3 20V7C3 6.44772 3.44772 6 4 6H10ZM21 3V11H19L18.9999 6.413L11.2071 14.2071L9.79289 12.7929L17.5849 5H13V3H21Z"/>
            </svg>
            ZenHub Workspace
          </a>
          <a href="<%= params[:github_url] %>" target="_blank" class="hover:text-gray-900 flex items-center gap-1">
            <svg class="w-4 h-4" viewBox="0 0 24 24" fill="currentColor">
              <path d="M10 6V8H5V19H16V14H18V20C18 20.5523 17.5523 21 17 21H4C3.44772 21 3 20.5523 3 20V7C3 6.44772 3.44772 6 4 6H10ZM21 3V11H19L18.9999 6.413L11.2071 14.2071L9.79289 12.7929L17.5849 5H13V3H21Z"/>
            </svg>
            GitHub Project
          </a>
        </div>
        <a href="<%= params[:github_url] %>/settings/fields/<%= @github_status_field&.dig('name') %>" 
           target="_blank" 
           class="text-sm text-gray-600 hover:text-gray-900 flex items-center gap-1">
          <svg class="w-4 h-4" viewBox="0 0 24 24" fill="currentColor">
            <path d="M10 6V8H5V19H16V14H18V20C18 20.5523 17.5523 21 17 21H4C3.44772 21 3 20.5523 3 20V7C3 6.44772 3.44772 6 4 6H10ZM21 3V11H19L18.9999 6.413L11.2071 14.2071L9.79289 12.7929L17.5849 5H13V3H21Z"/>
          </svg>
          Need to add a Status?
        </a>
      </div>
      <div class="bg-white shadow rounded-lg overflow-hidden">
        <table class="min-w-full divide-y divide-gray-300">
          <thead class="bg-gray-50">
            <tr>
              <th scope="col" class="py-3.5 pl-4 pr-3 text-left text-sm font-semibold text-gray-900">Pipeline</th>
              <th scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">GitHub Status</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-200">
            <% @workspace.pipelines.each do |pipeline| %>
              <tr class="hover:bg-gray-50 cursor-pointer" onclick="toggleAccordion('<%= pipeline.id %>')">
                <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm">
                  <div class="flex items-center">
                    <svg id="arrow-<%= pipeline.id %>" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-4 transition-transform duration-200 mr-2">
                      <path stroke-linecap="round" stroke-linejoin="round" d="m8.25 4.5 7.5 7.5-7.5 7.5" />
                    </svg>
                    <span class="font-medium text-gray-900"><%= pipeline.name %></span>
                    <span class="text-gray-500 ml-2">(<%= @pipeline_data[pipeline.id][:count] %> issues)</span>
                  </div>
                </td>
                <td class="whitespace-nowrap px-3 py-4 text-sm">
                  <select class="block w-full rounded-md border-0 py-1.5 pl-3 pr-10 text-gray-900 ring-1 ring-inset ring-gray-300 focus:ring-2 focus:ring-indigo-600 sm:text-sm/6" 
                          onclick="event.stopPropagation()"
                          onchange="handleSprintSelect(this)">
                    <% @github_status_options&.each do |option| %>
                      <option value="<%= option['id'] %>"><%= option['name'] %></option>
                    <% end %>
                  </select>
                </td>
              </tr>
              <tr id="content-<%= pipeline.id %>" class="hidden">
                <td colspan="2" class="px-0 border-t border-gray-200">
                  <div class="overflow-x-auto">
                    <table class="min-w-full divide-y divide-gray-300">
                      <thead class="bg-gray-50">
                        <tr>
                          <th scope="col" class="py-3.5 pl-4 pr-3 text-left text-sm font-semibold text-gray-900 pl-8">Issue</th>
                          <th scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Title</th>
                          <th scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Points</th>
                          <th scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Sprint</th>
                        </tr>
                      </thead>
                      <tbody class="divide-y divide-gray-200 bg-white">
                        <% @pipeline_data[pipeline.id][:issues].each do |issue| %>
                          <tr class="issue-row">
                            <td class="whitespace-nowrap py-4 pl-8 pr-3 text-sm">
                              <input type="checkbox" 
                                     class="issue-checkbox mr-2"
                                     data-issue-number="<%= issue.number %>"
                                     onclick="event.stopPropagation(); handleIssueCheckbox(this)">
                              <a href="<%= issue.html_url %>" target="_blank" class="text-blue-600 hover:text-blue-800">
                                #<%= issue.number %>
                              </a>
                            </td>
                            <td class="whitespace-normal px-3 py-4 text-sm text-gray-700">
                              <%= issue.title %>
                            </td>
                            <td class="whitespace-nowrap px-3 py-4 text-sm">
                              <% if issue.estimate&.value %>
                                <span class="inline-flex items-center rounded-md bg-gray-100 px-2 py-1 text-xs font-medium text-gray-600">
                                  <%= issue.estimate.value.round %> points
                                </span>
                              <% end %>
                            </td>
                            <td class="whitespace-nowrap px-3 py-4 text-sm">
                              <% if issue.sprints.total_count > 0 %>
                                <span class="inline-flex items-center rounded-md bg-blue-100 px-2 py-1 text-xs font-medium text-blue-700">
                                  <%= issue.sprints.nodes.first.name %>
                                </span>
                              <% end %>
                            </td>
                          </tr>
                        <% end %>
                      </tbody>
                    </table>
                  </div>
                </td>
              </tr>
          </div>
        <% end %>
      </div>
    </div>
  <% end %>
</div>

@@layout
<!DOCTYPE html>
<html>
<head>
  <title>ZenHub Pipeline Viewer</title>
  <script src="https://cdn.tailwindcss.com?plugins=forms"></script>
  <script>
    let selectedIssues = {
      metadata: {
        zenhubWorkspaceId: "<%= @workspace.id %>",
        githubProject: {
          organization: "<%= extract_github_project_info(params[:github_url])[:organization] %>",
          projectNumber: "<%= extract_github_project_info(params[:github_url])[:project_number] %>"
        }
      }
    };

    function handleSprintCheckbox(checkbox) {
      const sprintName = checkbox.dataset.sprintName;
      const issues = document.querySelectorAll(`.issue-row[data-sprint-name="${sprintName}"] .issue-checkbox`);
      const sprintRow = checkbox.closest('tr');
      const githubSprintSelect = sprintRow.querySelector('select');
      const githubSprintOption = githubSprintSelect.options[githubSprintSelect.selectedIndex];
      
      issues.forEach(issueCheckbox => {
        issueCheckbox.checked = checkbox.checked;
        const issueRow = issueCheckbox.closest('tr');
        const issueLink = issueRow.querySelector('a[href]');
        const issueUrl = issueLink.href;
        
        if (checkbox.checked && githubSprintOption.value !== "") {
          selectedIssues[issueUrl] = {
            fromZenHubSprint: sprintName,
            toGitHubSprint: {
              id: githubSprintOption.value,
              name: githubSprintOption.text
            }
          };
        } else {
          delete selectedIssues[issueUrl];
        }
      });
      
      updateJsonDisplay();
    }

    function handleSprintSelect(select) {
      const sprintRow = select.closest('tr');
      const sprintName = sprintRow.querySelector('.sprint-checkbox')?.dataset.sprintName;
      const selectedOption = select.options[select.selectedIndex];
      
      // Find all checked issue checkboxes for this sprint
      const checkedIssues = document.querySelectorAll(
        `.issue-row[data-sprint-name="${sprintName}"] .issue-checkbox:checked`
      );
      
      checkedIssues.forEach(checkbox => {
        const issueNumber = checkbox.dataset.issueNumber;
        const issueRow = checkbox.closest('tr');
        const issueLink = issueRow.querySelector('a[href]');
        
        if (selectedOption.value !== "") {
          selectedIssues[issueNumber] = {
            fromSprint: sprintName,
            toSprint: {
              id: selectedOption.value,
              name: selectedOption.text
            },
            url: issueLink.href
          };
        } else {
          delete selectedIssues[issueNumber];
        }
      });
      
      updateJsonDisplay();
    }

    function handleIssueCheckbox(checkbox) {
      const sprintName = checkbox.dataset.sprintName;
      const issueRow = checkbox.closest('tr');
      const issueLink = issueRow.querySelector('a[href]');
      const issueUrl = issueLink.href;
      
      // Find the sprint's select element by traversing up to the sprint row
      let currentRow = issueRow;
      let sprintSelect = null;
      while (currentRow && !sprintSelect) {
        currentRow = currentRow.previousElementSibling;
        if (currentRow && !currentRow.classList.contains('issue-row')) {
          sprintSelect = currentRow.querySelector('select');
        }
      }
      
      if (checkbox.checked) {
        if (sprintSelect) {
          const selectedOption = sprintSelect.options[sprintSelect.selectedIndex];
          selectedIssues[issueUrl] = {
            fromSprint: sprintName,
            toSprint: {
              id: selectedOption.value || null,
              name: selectedOption.text || "None"
            }
          };
        } else {
          selectedIssues[issueUrl] = {
            fromSprint: sprintName,
            toSprint: {
              id: null,
              name: "None"
            }
          };
        }
      } else {
        delete selectedIssues[issueUrl];
      }
      
      // Update the sprint checkbox based on all issue checkboxes
      const sprintCheckbox = document.querySelector(`.sprint-checkbox[data-sprint-name="${sprintName}"]`);
      const allIssues = document.querySelectorAll(`.issue-row[data-sprint-name="${sprintName}"] .issue-checkbox`);
      const checkedIssues = Array.from(allIssues).filter(issueCheckbox => issueCheckbox.checked);
      
      if (checkedIssues.length === allIssues.length) {
        sprintCheckbox.checked = true;
        sprintCheckbox.indeterminate = false;
      } else if (checkedIssues.length > 0) {
        sprintCheckbox.checked = false;
        sprintCheckbox.indeterminate = true;
      } else {
        sprintCheckbox.checked = false;
        sprintCheckbox.indeterminate = false;
      }
      
      updateJsonDisplay();
    }

    function updateJsonDisplay() {
      const jsonDisplay = document.getElementById('selected-issues-json');
      if (Object.keys(selectedIssues).length > 1) { // Exclude metadata from count
        const prettyJson = JSON.stringify(selectedIssues, null, 2);
        jsonDisplay.innerHTML = `<pre class="text-xs font-mono">${prettyJson}</pre>`;
        jsonDisplay.classList.remove('hidden');
      } else {
        jsonDisplay.innerHTML = '';
        jsonDisplay.classList.add('hidden');
      }
    }
    function toggleAccordion(id) {
      const content = document.getElementById(`content-${id}`);
      const arrow = document.getElementById(`arrow-${id}`);
      
      if (content.classList.contains('hidden')) {
        content.classList.remove('hidden');
        arrow.classList.add('rotate-90');
      } else {
        content.classList.add('hidden');
        arrow.classList.remove('rotate-90');
      }
    }
  </script>
</head>
<body class="bg-gray-100">
  <%= yield %>
  <div class="pb-[35vh]"></div>
</body>
</html>

@@setup
<div class="min-h-full flex flex-col justify-center py-12 sm:px-6 lg:px-8">
  <% if @workspace %>
    <div class="sm:mx-auto sm:w-full sm:max-w-4xl">
        <h2 class="text-2xl font-bold mb-2"><%= @workspace.display_name %></h2>
        <div class="flex gap-4 mb-4 text-sm text-gray-600">
          <a href="<%= params[:workspace_url] %>" target="_blank" class="hover:text-gray-900 flex items-center gap-1">
            <svg class="w-4 h-4" viewBox="0 0 24 24" fill="currentColor">
              <path d="M10 6V8H5V19H16V14H18V20C18 20.5523 17.5523 21 17 21H4C3.44772 21 3 20.5523 3 20V7C3 6.44772 3.44772 6 4 6H10ZM21 3V11H19L18.9999 6.413L11.2071 14.2071L9.79289 12.7929L17.5849 5H13V3H21Z"/>
            </svg>
            ZenHub Workspace
          </a>
          <a href="<%= params[:github_url] %>" target="_blank" class="hover:text-gray-900 flex items-center gap-1">
            <svg class="w-4 h-4" viewBox="0 0 24 24" fill="currentColor">
              <path d="M10 6V8H5V19H16V14H18V20C18 20.5523 17.5523 21 17 21H4C3.44772 21 3 20.5523 3 20V7C3 6.44772 3.44772 6 4 6H10ZM21 3V11H19L18.9999 6.413L11.2071 14.2071L9.79289 12.7929L17.5849 5H13V3H21Z"/>
            </svg>
            GitHub Project
          </a>
        </div>
        <% if @sprints.any? %>
          <div class="mb-6">
            <div class="flex justify-between items-center mb-2">
              <h3 class="text-lg font-medium text-gray-900">Sprint Mapping</h3>
              <div id="selected-issues-json" class="text-xs text-gray-500 mt-2 whitespace-pre-wrap hidden"></div>
              <a href="<%= params[:github_url] %>/settings/fields/<%= @github_sprint_field.dig('databaseId') %>" 
                 target="_blank" 
                 class="text-sm text-gray-600 hover:text-gray-900 flex items-center gap-1">
                <svg class="w-4 h-4" viewBox="0 0 24 24" fill="currentColor">
                  <path d="M10 6V8H5V19H16V14H18V20C18 20.5523 17.5523 21 17 21H4C3.44772 21 3 20.5523 3 20V7C3 6.44772 3.44772 6 4 6H10ZM21 3V11H19L18.9999 6.413L11.2071 14.2071L9.79289 12.7929L17.5849 5H13V3H21Z"/>
                </svg>
                Need to add a Sprint?
              </a>
            </div>
            <div class="overflow-hidden shadow ring-1 ring-black ring-opacity-5 sm:rounded-lg">
              <table class="min-w-full divide-y divide-gray-300">
                <thead class="bg-gray-50">
                  <tr>
                    <th scope="col" class="py-3.5 pl-4 pr-3 text-left text-sm font-semibold text-gray-900">ZenHub Sprint</th>
                    <th scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">GitHub Sprint</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-200 bg-white">
                  <% 
                    # Sort sprints by start date
                    sorted_sprints = @sprints.sort_by { |sprint| -Date.parse(sprint.start_at).to_time.to_i }
                    sorted_sprints.each do |sprint| 
                  %>
                    <tr>
                      <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm font-medium text-gray-900">
                        <%= sprint.name %>
                        <span class="text-xs text-gray-500 ml-2">
                          (<%= sprint.id %>)
                        </span>
                      </td>
                      <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500 text-right">
                        <select class="block w-full rounded-md border-0 py-1.5 pl-3 pr-10 text-gray-900 ring-1 ring-inset ring-gray-300 focus:ring-2 focus:ring-indigo-600 sm:text-sm/6">
                          <option value="">None</option>
                          <% 
                            all_iterations = (@github_sprint_field&.dig('configuration', 'iterations') || []) +
                                           (@github_sprint_field&.dig('configuration', 'completedIterations') || [])
                            # Sort iterations by start date
                            all_iterations = all_iterations.sort_by { |i| Date.parse(i['startDate']) }
                            all_iterations.each do |iteration| 
                          %>
                            <% 
                              # Find matching sprint in pipeline data
                              matching_sprint = sprint.start_at && 
                                (Date.parse(sprint.start_at) - Date.parse(iteration['startDate'])).abs <= 1
                            %>
                            <%
                              start_date = Date.parse(iteration['startDate'])
                              end_date = start_date + iteration['duration'].to_i - 1
                              date_range = "#{start_date.strftime('%b %-d')} - #{end_date.strftime('%b %-d, %Y')}"
                            %>
                            <option value="<%= iteration['id'] %>" <%= 'selected' if matching_sprint %>>
                              <%= iteration['title'] %> (<%= date_range %>)
                            </option>
                          <% end %>
                        </select>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </div>
        <% end %>
        <div class="space-y-4">
          <% @workspace.pipelines.each do |pipeline| %>
            <div class="bg-white shadow rounded-lg">
              <div class="p-4 flex justify-between items-center">
                <button onclick="toggleAccordion('<%= pipeline.id %>')" class="flex-1 text-left flex items-center">
                  <h3 class="text-lg font-medium text-gray-900">
                    <%= pipeline.name %> 
                    <span class="text-sm text-gray-500"><%= @pipeline_data[pipeline.id][:count] %> issues</span>
                  </h3>

                  <svg id="arrow-<%= pipeline.id %>" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-4 transition-transform duration-200 ml-2">
                    <path stroke-linecap="round" stroke-linejoin="round" d="m8.25 4.5 7.5 7.5-7.5 7.5" />
                  </svg>
                </button>
                <div class="ml-4">
                  <select class="block w-full rounded-md border-0 py-1.5 pl-3 pr-10 text-gray-900 ring-1 ring-inset ring-gray-300 focus:ring-2 focus:ring-indigo-600 sm:text-sm/6">
                    <% @github_status_options&.each do |option| %>
                      <option value="<%= option['id'] %>"><%= option['name'] %></option>
                    <% end %>
                  </select>
                </div>
              </div>
                <tr id="content-<%= pipeline.id %>" class="hidden">
                  <td colspan="2" class="px-0 border-t border-gray-200">
                    <div class="overflow-x-auto">
                      <table class="min-w-full divide-y divide-gray-300">
                    <thead class="bg-gray-50">
                      <tr>
                        <th scope="col" class="py-3.5 pl-4 pr-3 text-left text-sm font-semibold text-gray-900">Issue</th>
                        <th scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Title</th>
                        <th scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Points</th>
                        <th scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Sprint</th>
                      </tr>
                    </thead>
                    <tbody class="divide-y divide-gray-200 bg-white">
                      <% @pipeline_data[pipeline.id][:issues].each do |issue| %>
                        <tr>
                          <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm">
                            <a href="<%= issue.html_url %>" target="_blank" class="text-blue-600 hover:text-blue-800">
                              #<%= issue.number %>
                            </a>
                          </td>
                          <td class="whitespace-normal px-3 py-4 text-sm text-gray-700">
                            <%= issue.title %>
                          </td>
                          <td class="whitespace-nowrap px-3 py-4 text-sm">
                            <% if issue.estimate&.value %>
                              <span class="inline-flex items-center rounded-md bg-gray-100 px-2 py-1 text-xs font-medium text-gray-600">
                                <%= issue.estimate.value.round %> points
                              </span>
                            <% end %>
                          </td>
                          <td class="whitespace-nowrap px-3 py-4 text-sm">
                            <% if issue.sprints.total_count > 0 %>
                              <span class="inline-flex items-center rounded-md bg-blue-100 px-2 py-1 text-xs font-medium text-blue-700">
                                <%= issue.sprints.nodes.first.name %>
                              </span>
                            <% end %>
                          </td>
                        </tr>
                      <% end %>
                    </tbody>
                      </table>
                    </div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
    </div>
  <% else %>
    <div class="sm:mx-auto sm:w-full sm:max-w-md">
      <h2 class="mt-6 text-center text-3xl font-bold tracking-tight text-gray-900">Connect Your Project</h2>
      <p class="mt-2 text-center text-sm text-gray-600">
        Enter both your ZenHub workspace and GitHub project URLs
      </p>
    </div>

    <div class="mt-8 sm:mx-auto sm:w-full sm:max-w-md">
      <div class="bg-white py-8 px-4 shadow sm:rounded-lg sm:px-10">
        <form class="space-y-6" method="GET" action="/pipelines">
          <div>
            <label for="workspace_url" class="block text-sm font-medium text-gray-700">ZenHub Workspace URL</label>
            <div class="mt-1">
              <input id="workspace_url" name="workspace_url" type="text" required autofocus
                     placeholder="https://app.zenhub.com/workspaces/workspace-name-id"
                     class="block w-full appearance-none rounded-md border border-gray-300 px-3 py-2 placeholder-gray-400 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-indigo-500 sm:text-sm">
            </div>
          </div>

          <div>
            <label for="github_url" class="block text-sm font-medium text-gray-700">GitHub Project URL</label>
            <div class="mt-1">
              <input id="github_url" name="github_url" type="text" required
                     placeholder="https://github.com/orgs/owner/projects/1"
                     class="block w-full appearance-none rounded-md border border-gray-300 px-3 py-2 placeholder-gray-400 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-indigo-500 sm:text-sm">
            </div>
          </div>

          <div>
            <button type="submit" class="flex w-full justify-center rounded-md border border-transparent bg-indigo-600 py-2 px-4 text-sm font-medium text-white shadow-sm hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2">
              View Workspace
            </button>
          </div>
        </form>
      </div>
    </div>
  <% end %>
</div>
