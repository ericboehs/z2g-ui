require 'logger'
$logger ||= Logger.new $stdout

require 'bundler/setup'

require 'sinatra/base'
require 'sinatra/session'
require 'graphql/client'
require 'graphql/client/http'
require 'uri'
require 'net/http'
require 'json'
require 'fileutils'
require 'ostruct'
require_relative 'github_project'

class App < Sinatra::Base
  set :server, :puma
  enable :sessions
  set :session_secret, ENV.fetch('SESSION_SECRET')
  
  # Class-level cache for API responses
  @@zenhub_cache = {}
  @@github_cache = {}
  
  # Cache expiration time (1 hour)
  CACHE_EXPIRY = 3600
  CACHE_DIR = 'cache'

  def self.save_caches
    FileUtils.mkdir_p(CACHE_DIR)
    
    File.write(File.join(CACHE_DIR, 'zenhub_cache.json'), JSON.pretty_generate(@@zenhub_cache))
    File.write(File.join(CACHE_DIR, 'github_cache.json'), JSON.pretty_generate(@@github_cache))
    $logger.info "Saved caches to #{CACHE_DIR}/"
  end

  def self.load_caches
    return unless File.directory?(CACHE_DIR)

    zenhub_cache_file = File.join(CACHE_DIR, 'zenhub_cache.json')
    github_cache_file = File.join(CACHE_DIR, 'github_cache.json')

    if File.exist?(zenhub_cache_file)
      @@zenhub_cache = JSON.parse(File.read(zenhub_cache_file), symbolize_names: true)
      $logger.info "Loaded ZenHub cache from #{zenhub_cache_file}"
    end

    if File.exist?(github_cache_file)
      @@github_cache = JSON.parse(File.read(github_cache_file), symbolize_names: true)
      $logger.info "Loaded GitHub cache from #{github_cache_file}"
    end
  end

  # GraphQL client setup
  class ZenhubHTTP < GraphQL::Client::HTTP
    def headers(context)
      { "Authorization": "Bearer #{context[:token]}" }
    end
  end

  HTTP = ZenhubHTTP.new('https://api.zenhub.com/public/graphql')
  Schema = GraphQL::Client.load_schema("zenhub_schema.json")
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

  helpers do
    def require_tokens
      if session[:github_token].nil? || session[:zenhub_token].nil?
        redirect "/connect?#{request.query_string}"
      end
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
      all_issues = []
      has_next_page = true
      cursor = nil

      while has_next_page
        result = Client.query(
          PipelineIssuesQuery,
          variables: {
            pipelineId: pipeline_id,
            numberOfIssues: 100,
            issuesAfter: cursor,
            filters: {
              matchType: "all",
              repositoryIds: repository_ids
            },
          },
          context: { token: session[:zenhub_token] }
        )

        page_info = result.data.search_issues_by_pipeline.page_info
        has_next_page = page_info.has_next_page
        cursor = page_info.end_cursor

        all_issues.concat(result.data.search_issues_by_pipeline.nodes)
        
        # Add a small delay to avoid rate limiting
        sleep(0.5) if has_next_page
      end

      # Create a wrapper object that mimics the structure of a single page response
      OpenStruct.new(
        data: OpenStruct.new(
          search_issues_by_pipeline: OpenStruct.new(
            nodes: all_issues,
            pipeline_counts: OpenStruct.new(
              issues_count: all_issues.length
            )
          )
        )
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
      $logger.info "Querying ZenHub workspace: #{workspace_id}"
      result = Client.query(
        PipelinesQuery,
        variables: { workspaceId: workspace_id },
        context: { token: session[:zenhub_token] }
      )
      @workspace = result.data.workspace.to_hash if result.data&.workspace

      # Fetch issue counts for each pipeline
      if @workspace
        repository_ids = @workspace["repositories"].map { |repo| repo["id"] }
        @pipeline_data = {}
        @workspace["pipelines"].each do |pipeline|
          $logger.info "Fetching issues for pipeline: #{pipeline['name']} (#{pipeline['id']})"
          issues_result = fetch_pipeline_issues(workspace_id, pipeline['id'], repository_ids)
          issues = issues_result.data.search_issues_by_pipeline.nodes
          @pipeline_data[pipeline['id']] = {
            count: issues_result.data.search_issues_by_pipeline.pipeline_counts.issues_count,
            issues: issues
          }
        end
        @pipeline_data = @pipeline_data.transform_values { |data|
          {
            count: data[:count],
            issues: data[:issues].map(&:to_hash)
          }
        }

        # Get sprints directly from workspace
        @sprints = query_workspace_sprints(workspace_id).map(&:to_hash)

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
      $logger.info "Querying ZenHub sprints for workspace: #{workspace_id}"
      result = Client.query(
        WorkspaceSprintsQuery,
        variables: { workspaceId: workspace_id },
        context: { token: session[:zenhub_token] }
      )
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
          @github_issues = cached[:issues]
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
      request['Authorization'] = "Bearer #{session[:github_token]}"
      request['Content-Type'] = 'application/json'
      request.body = { query: github_query }.to_json

      $logger.info "Querying GitHub project: #{github_info[:organization]}/#{github_info[:project_number]}"
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
        status_request['Authorization'] = "Bearer #{session[:github_token]}"
        status_request['Content-Type'] = 'application/json'
        status_request.body = { query: status_query }.to_json

        $logger.info "Querying GitHub project status fields for: #{@github_project_id}"
        status_response = http.request(status_request)
        if status_response.is_a?(Net::HTTPSuccess)
          status_data = JSON.parse(status_response.body)
          @github_status_options = status_data.dig('data', 'node', 'statusField', 'options')
          @github_sprint_field = status_data.dig('data', 'node', 'sprintField')
          @github_status_field = status_data.dig('data', 'node', 'statusField')

          # Cache the results
          github_project = Github::Project.new(
            token: session[:github_token], organization: github_info[:organization], number: github_info[:project_number]
          )
          @github_issues = github_project.issues.map(&:to_hash)

          @@github_cache[cache_key] = {
            project_id: @github_project_id,
            status_options: @github_status_options,
            status_field: @github_status_field,
            sprint_field: @github_sprint_field,
            issues: @github_issues,
            timestamp: Time.now.to_i
          }
        end
      end
    end
  end

  get '/' do
    redirect '/connect'
  end

  post '/set-connection' do
    content_type :json
    
    # Validate and set tokens in session
    if params[:github_token].to_s.empty? || params[:zenhub_token].to_s.empty?
      status 400
      return {error: "Both GitHub and ZenHub tokens are required"}.to_json
    end

    session[:github_token] = params[:github_token]
    session[:zenhub_token] = params[:zenhub_token]
    
    # Redirect to pipelines while preserving workspace_url and github_url parameters
    redirect "/pipelines?workspace_url=#{URI.encode_www_form_component(params[:workspace_url])}&github_url=#{URI.encode_www_form_component(params[:github_url])}"
  end

  get '/connect' do
    steps = [
      { name: "Connect", number: "01", current: true, completed: false, url: "/connect" },
      { name: "Pipelines", number: "02", current: false, completed: false, url: "/pipelines?#{request.query_string}" },
      { name: "Points", number: "03", current: false, completed: false, url: "/points?#{request.query_string}" },
      { name: "Sprints", number: "04", current: false, completed: false, url: "/sprints?#{request.query_string}" },
      { name: "Review", number: "05", current: false, completed: false, url: "/review?#{request.query_string}" }
    ]

    erb :connect, locals: { steps: steps }
  end

  get '/pipelines' do
    require_tokens
    workspace_id = extract_workspace_id(params[:workspace_url])
    github_info = extract_github_project_info(params[:github_url])
    
    if workspace_id.nil? || github_info.nil?
      status 400
      return "Please provide valid ZenHub workspace and GitHub project URLs."
    end

    query_zenhub_workspace(workspace_id)
    query_github_project(github_info)
    App.save_caches

    steps = [
      { name: "Connect", number: "01", current: false, completed: true, url: "/connect?#{request.query_string}" },
      { name: "Pipelines", number: "02", current: true, completed: false, url: "/pipelines?#{request.query_string}" },
      { name: "Points", number: "03", current: false, completed: false, url: "/points?#{request.query_string}" },
      { name: "Sprints", number: "04", current: false, completed: false, url: "/sprints?#{request.query_string}" },
      { name: "Review", number: "05", current: false, completed: false, url: "/review?#{request.query_string}" }
    ]

    erb :pipelines, locals: { steps: steps }
  end

  get '/points' do
    require_tokens
    workspace_id = extract_workspace_id(params[:workspace_url])
    github_info = extract_github_project_info(params[:github_url])
    
    if workspace_id.nil? || github_info.nil?
      status 400
      return "Please provide valid ZenHub workspace and GitHub project URLs."
    end

    query_zenhub_workspace(workspace_id)
    query_github_project(github_info)
    App.save_caches

    steps = [
      { name: "Connect", number: "01", current: false, completed: true, url: "/connect?#{request.query_string}" },
      { name: "Pipelines", number: "02", current: false, completed: true, url: "/pipelines?#{request.query_string}" },
      { name: "Points", number: "03", current: true, completed: false, url: "/points?#{request.query_string}" },
      { name: "Sprints", number: "04", current: false, completed: false, url: "/sprints?#{request.query_string}" },
      { name: "Review", number: "05", current: false, completed: false, url: "/review?#{request.query_string}" }
    ]

    erb :points, locals: { steps: steps }
  end

  get '/sprints' do
    require_tokens
    workspace_id = extract_workspace_id(params[:workspace_url])
    github_info = extract_github_project_info(params[:github_url])
    
    if workspace_id.nil? || github_info.nil?
      status 400
      return "Please provide valid ZenHub workspace and GitHub project URLs."
    end

    query_zenhub_workspace(workspace_id)
    query_github_project(github_info)
    App.save_caches

    steps = [
      { name: "Connect", number: "01", current: false, completed: true, url: "/connect?#{request.query_string}" },
      { name: "Pipelines", number: "02", current: false, completed: true, url: "/pipelines?#{request.query_string}" },
      { name: "Points", number: "03", current: false, completed: true, url: "/points?#{request.query_string}" },
      { name: "Sprints", number: "04", current: true, completed: false, url: "/sprints?#{request.query_string}" },
      { name: "Review", number: "05", current: false, completed: false, url: "/review?#{request.query_string}" }
    ]

    erb :sprints, locals: { steps: steps }
  end

  get '/review' do
    # Implement migration logic here
    steps = [
      { name: "Connect", number: "01", current: false, completed: true, url: "/connect?#{request.query_string}" },
      { name: "Pipelines", number: "02", current: false, completed: true, url: "/pipelines?#{request.query_string}" },
      { name: "Points", number: "03", current: false, completed: true, url: "/points?#{request.query_string}" },
      { name: "Sprints", number: "04", current: false, completed: true, url: "/sprints?#{request.query_string}" },
      { name: "Review", number: "05", current: true, completed: false, url: "/review?#{request.query_string}" }
    ]

    erb :review, locals: { steps: steps }
  end

  post '/migrate' do
    require_tokens
    
    begin
      # Parse the JSON data from form
      status_mappings = JSON.parse(params[:statusMappings])
      sprint_mappings = JSON.parse(params[:sprintMappings]) 
      points_mappings = JSON.parse(params[:pointsMappings])
      
      # Log the mappings to stdout
      puts "\n=== Migration Started ==="
      puts "\nStatus Mappings:"
      pp status_mappings
      puts "\nSprint Mappings:"
      pp sprint_mappings
      puts "\nPoints Mappings:" 
      pp points_mappings
      puts "\n=== Migration Complete ===\n"
      
      # Redirect to done page
      redirect "/done"
    rescue JSON::ParserError => e
      status 400
      "Invalid JSON data received: #{e.message}"
    rescue => e
      status 500
      "Migration failed: #{e.message}"
    end
  end

  get '/done' do
    erb :done
  end

  get '/clear-cache' do
    @@zenhub_cache.clear
    @@github_cache.clear
    App.save_caches
    redirect back
  end
end

if __FILE__ == $0
  App.load_caches
  at_exit { App.save_caches }
  App.run!
end
