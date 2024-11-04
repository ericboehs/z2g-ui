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
  end

  get '/' do
    erb :index
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

    # Query ZenHub
    result = Client.query(PipelinesQuery, variables: { workspaceId: workspace_id })
    @workspace = result.data.workspace if result.data

    # Fetch issue counts for each pipeline
    if @workspace
      repository_ids = @workspace.repositories.map(&:id)
      @pipeline_issues = {}
      @workspace.pipelines.each do |pipeline|
        issues_result = fetch_pipeline_issues(workspace_id, pipeline.id, repository_ids)
        @pipeline_issues[pipeline.id] = issues_result.data.search_issues_by_pipeline.pipeline_counts.issues_count
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
              field(name: "Status") {
                ... on ProjectV2SingleSelectField {
                  id
                  name
                  options {
                    id
                    name
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
        @github_status_options = status_data.dig('data', 'node', 'field', 'options')
      end
    end

    erb :index
  end
end

App.run! if __FILE__ == $0

__END__

@@layout
<!DOCTYPE html>
<html>
<head>
  <title>ZenHub Pipeline Viewer</title>
  <script src="https://cdn.tailwindcss.com?plugins=forms"></script>
</head>
<body class="bg-gray-100">
  <%= yield %>
</body>
</html>

@@index
<div class="min-h-full flex flex-col justify-center py-12 sm:px-6 lg:px-8">
  <% if @workspace %>
    <div class="sm:mx-auto sm:w-full sm:max-w-4xl">
        <h2 class="text-2xl font-bold mb-4"><%= @workspace.display_name %></h2>
        <div class="space-y-4">
          <% @workspace.pipelines.each do |pipeline| %>
            <div class="bg-white shadow rounded-lg p-4 flex justify-between items-center">
              <h3 class="text-lg font-medium text-gray-900">
                <%= pipeline.name %> 
                <span class="text-sm text-gray-500">(<%= @pipeline_issues[pipeline.id] %> issues)</span>
              </h3>
              <div class="ml-4">
                <select class="mt-2 block w-full rounded-md border-0 py-1.5 pl-3 pr-10 text-gray-900 ring-1 ring-inset ring-gray-300 focus:ring-2 focus:ring-indigo-600 sm:text-sm/6">
                  <option value="">None</option>
                  <% @github_status_options&.each do |option| %>
                    <option value="<%= option['id'] %>"><%= option['name'] %></option>
                  <% end %>
                </select>
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
