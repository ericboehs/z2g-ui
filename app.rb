require 'bundler/inline'
require 'set'

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
    def setup_workspace_data(workspace_id, github_info)
      # Query ZenHub
      result = Client.query(PipelinesQuery, variables: { workspaceId: workspace_id })
      @workspace = result.data.workspace if result.data

      # Fetch issue counts for each pipeline and collect unique sprints
      if @workspace
        repository_ids = @workspace.repositories.map(&:id)
        @pipeline_data = {}
        @all_sprints = Set.new
        @workspace.pipelines.each do |pipeline|
          issues_result = fetch_pipeline_issues(workspace_id, pipeline.id, repository_ids)
          issues = issues_result.data.search_issues_by_pipeline.nodes
          issues.each do |issue|
            if issue.sprints.total_count > 0
              @all_sprints.add(issue.sprints.nodes.first.name)
            end
          end
          @pipeline_data[pipeline.id] = {
            count: issues_result.data.search_issues_by_pipeline.pipeline_counts.issues_count,
            issues: issues
          }
        end
      end

      setup_github_data(github_info)
    end

    def setup_github_data(github_info)
      fetch_github_project_id(github_info)
      fetch_github_fields if @github_project_id
    end

    def fetch_github_project_id(github_info)
      github_query = <<~GRAPHQL
        query {
          organization(login: "#{github_info[:organization]}") {
            projectV2(number: #{github_info[:project_number]}) {
              id
            }
          }
        }
      GRAPHQL

      response = github_graphql_request(github_query)
      if response.is_a?(Net::HTTPSuccess)
        github_data = JSON.parse(response.body)
        @github_project_id = github_data.dig('data', 'organization', 'projectV2', 'id')
      end
    end

    def fetch_github_fields
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
      GRAPHQL

      response = github_graphql_request(status_query)
      if response.is_a?(Net::HTTPSuccess)
        status_data = JSON.parse(response.body)
        @github_status_options = status_data.dig('data', 'node', 'statusField', 'options')
        @github_sprint_field = status_data.dig('data', 'node', 'sprintField')
      end
    end

    def github_graphql_request(query)
      uri = URI('https://api.github.com/graphql')
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      
      request = Net::HTTP::Post.new(uri)
      request['Authorization'] = "Bearer #{ENV['GITHUB_TOKEN']}"
      request['Content-Type'] = 'application/json'
      request.body = { query: query }.to_json

      http.request(request)
    end

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
      # Query ZenHub
      result = Client.query(PipelinesQuery, variables: { workspaceId: workspace_id })
      @workspace = result.data.workspace if result.data

      # Fetch issue counts for each pipeline and collect unique sprints
      if @workspace
        repository_ids = @workspace.repositories.map(&:id)
        @pipeline_data = {}
        @all_sprints = Set.new
        @workspace.pipelines.each do |pipeline|
          issues_result = fetch_pipeline_issues(workspace_id, pipeline.id, repository_ids)
          issues = issues_result.data.search_issues_by_pipeline.nodes
          issues.each do |issue|
            if issue.sprints.total_count > 0
              @all_sprints.add(issue.sprints.nodes.first.name)
            end
          end
          @pipeline_data[pipeline.id] = {
            count: issues_result.data.search_issues_by_pipeline.pipeline_counts.issues_count,
            issues: issues
          }
        end
      end
    end

    def query_github_project(github_info)
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
      setup_workspace_data(workspace_id, github_info)
      if @workspace.nil?
        status 400
        return "Could not fetch workspace data. Please ensure your ZenHub token is valid and you have access to this workspace."
      end

      query_zenhub_workspace(workspace_id)
      query_github_project(github_info)

      erb :sprints
    end
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
        </div>
      </div>
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
      <% if @all_sprints.any? %>
        <div class="mb-6">
          <div class="flex justify-between items-center mb-2">
            <h3 class="text-lg font-medium text-gray-900">Sprint Mapping</h3>
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
                  sprint_dates = @pipeline_data.values.flat_map { |data| 
                    data[:issues].flat_map { |issue| 
                      issue.sprints.nodes.map { |sprint| [sprint.name, Date.parse(sprint.start_at)] if sprint.start_at }
                    }
                  }.compact.uniq
                  sorted_sprints = sprint_dates.sort_by { |_, date| date }.map(&:first)
                  sorted_sprints.each do |sprint| 
                %>
                  <tr>
                    <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm font-medium text-gray-900">
                      <%= sprint %>
                      <span class="text-xs text-gray-500 ml-2">
                        (<%= @pipeline_data.values.flat_map { |data| 
                          data[:issues].flat_map { |issue| 
                            issue.sprints.nodes.find { |s| s.name == sprint }&.id 
                          }
                        }.compact.first %>)
                      </span>
                    </td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">
                      <select class="block w-full rounded-md border-0 py-1.5 text-gray-900 shadow-sm ring-1 ring-inset ring-gray-300 focus:ring-2 focus:ring-inset focus:ring-indigo-600 sm:max-w-xs sm:text-sm sm:leading-6">
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
                              zh_sprint.name == sprint && 
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
        </div>
      </div>
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
            <div id="content-<%= pipeline.id %>" class="hidden border-t border-gray-200">
              <div class="p-4 space-y-2">
                <% @pipeline_data[pipeline.id][:issues].each do |issue| %>
                  <div class="flex items-center space-x-2">
                    <a href="<%= issue.html_url %>" target="_blank" class="text-blue-600 hover:text-blue-800">
                      #<%= issue.number %>
                    </a>
                    <span class="text-gray-700"><%= issue.title %></span>
                    <% if issue.estimate&.value %>
                      <span class="inline-flex items-center rounded-md bg-gray-100 px-2 py-1 text-xs font-medium text-gray-600">
                        <%= issue.estimate.value.round %> points
                      </span>
                    <% end %>
                    <% if issue.sprints.total_count > 0 %>
                      <span class="inline-flex items-center rounded-md bg-blue-100 px-2 py-1 text-xs font-medium text-blue-700">
                        <%= issue.sprints.nodes.first.name %>
                      </span>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
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
    function toggleAccordion(id) {
      const content = document.getElementById(`content-${id}`);
      const arrow = document.getElementById(`arrow-${id}`);
      
      content.classList.toggle('hidden');
      arrow.style.transform = content.classList.contains('hidden') ? '' : 'rotate(90deg)';
    }
  </script>
</head>
<body class="bg-gray-100">
  <%= yield %>
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
        <% if @all_sprints.any? %>
          <div class="mb-6">
            <div class="flex justify-between items-center mb-2">
              <h3 class="text-lg font-medium text-gray-900">Sprint Mapping</h3>
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
                    # Get all ZenHub sprints with their start dates
                    sprint_dates = @pipeline_data.values.flat_map { |data| 
                      data[:issues].flat_map { |issue| 
                        issue.sprints.nodes.map { |sprint| [sprint.name, Date.parse(sprint.start_at)] if sprint.start_at }
                      }
                    }.compact.uniq
                    # Sort sprints by start date
                    sorted_sprints = sprint_dates.sort_by { |_, date| date }.map(&:first)
                    sorted_sprints.each do |sprint| 
                  %>
                    <tr>
                      <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm font-medium text-gray-900">
                        <%= sprint %>
                        <span class="text-xs text-gray-500 ml-2">
                          (<%= @pipeline_data.values.flat_map { |data| 
                            data[:issues].flat_map { |issue| 
                              issue.sprints.nodes.find { |s| s.name == sprint }&.id 
                            }
                          }.compact.first %>)
                        </span>
                      </td>
                      <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">
                        <select class="block w-full rounded-md border-0 py-1.5 text-gray-900 shadow-sm ring-1 ring-inset ring-gray-300 focus:ring-2 focus:ring-inset focus:ring-indigo-600 sm:max-w-xs sm:text-sm sm:leading-6">
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
                              matching_sprint = @pipeline_data.values.flat_map { |data| 
                                data[:issues].flat_map { |issue| 
                                  issue.sprints.nodes
                                }
                              }.find { |zh_sprint| 
                                zh_sprint.name == sprint && 
                                zh_sprint.start_at && 
                                (Date.parse(zh_sprint.start_at) - Date.parse(iteration['startDate'])).abs <= 1
                              }
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
              <div id="content-<%= pipeline.id %>" class="hidden border-t border-gray-200">
                <div class="p-4 space-y-2">
                  <% @pipeline_data[pipeline.id][:issues].each do |issue| %>
                    <div class="flex items-center space-x-2">
                      <a href="<%= issue.html_url %>" target="_blank" class="text-blue-600 hover:text-blue-800">
                        #<%= issue.number %>
                      </a>
                      <span class="text-gray-700"><%= issue.title %></span>
                      <% if issue.estimate&.value %>
                        <span class="inline-flex items-center rounded-md bg-gray-100 px-2 py-1 text-xs font-medium text-gray-600">
                          <%= issue.estimate.value.round %> points
                        </span>
                      <% end %>
                      <% if issue.sprints.total_count > 0 %>
                        <span class="inline-flex items-center rounded-md bg-blue-100 px-2 py-1 text-xs font-medium text-blue-700">
                          <%= issue.sprints.nodes.first.name %>
                        </span>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>
          <% end %>
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
