require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'sinatra'
  gem 'graphql-client'
  gem 'puma'
  gem 'rack'
  gem 'rackup'
  gem 'uri'

  # Development gems
  gem 'pry'
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
    steps = [
      { name: "Setup", number: "01", current: true, completed: false, url: "/" },
      { name: "Pipelines", number: "02", current: false, completed: false, url: "/pipelines?#{request.query_string}" },
      { name: "Sprints", number: "03", current: false, completed: false, url: "/sprints?#{request.query_string}" },
      { name: "Migrate", number: "04", current: false, completed: false, url: "/migrate?#{request.query_string}" }
    ]
    erb :setup, locals: { steps: steps }
  end

  get '/pipelines' do
    workspace_id = extract_workspace_id(params[:workspace_url])
    github_info = extract_github_project_info(params[:github_url])
    
    if workspace_id.nil? || github_info.nil?
      status 400
      return "Please provide valid ZenHub workspace and GitHub project URLs."
    end

    query_zenhub_workspace(workspace_id)
    query_github_project(github_info)

    steps = [
      { name: "Setup", number: "01", current: false, completed: true, url: "/" },
      { name: "Pipelines", number: "02", current: true, completed: false, url: "/pipelines?#{request.query_string}" },
      { name: "Sprints", number: "03", current: false, completed: false, url: "/sprints?#{request.query_string}" },
      { name: "Migrate", number: "04", current: false, completed: false, url: "/migrate?#{request.query_string}" }
    ]
    erb :pipelines, locals: { steps: steps }
  end

  get '/sprints' do
    workspace_id = extract_workspace_id(params[:workspace_url])
    github_info = extract_github_project_info(params[:github_url])
    
    if workspace_id.nil? || github_info.nil?
      status 400
      return "Please provide valid ZenHub workspace and GitHub project URLs."
    end

    query_zenhub_workspace(workspace_id)
    query_github_project(github_info)

    steps = [
      { name: "Setup", number: "01", current: false, completed: true, url: "/" },
      { name: "Pipelines", number: "02", current: false, completed: true, url: "/pipelines?#{request.query_string}" },
      { name: "Sprints", number: "03", current: true, completed: false, url: "/sprints?#{request.query_string}" },
      { name: "Migrate", number: "04", current: false, completed: false, url: "/migrate?#{request.query_string}" }
    ]
    erb :sprints, locals: { steps: steps }
  end

  get '/migrate' do
    # Implement migration logic here
    steps = [
      { name: "Setup", number: "01", current: false, completed: true, url: "/" },
      { name: "Pipelines", number: "02", current: false, completed: true, url: "/pipelines?#{request.query_string}" },
      { name: "Sprints", number: "03", current: false, completed: true, url: "/sprints?#{request.query_string}" },
      { name: "Migrate", number: "04", current: true, completed: false, url: "/migrate?#{request.query_string}" }
    ]
    erb :migrate, locals: { steps: steps }
  end

  get '/clear-cache' do
    @@zenhub_cache.clear
    @@github_cache.clear
    redirect back
  end
end

App.run! if __FILE__ == $0
