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
    PipelinesQuery = Client.parse <<-GRAPHQL
      query($workspaceId: ID!) {
        workspace(id: $workspaceId) {
          id
          displayName
          pipelines {
            createdAt
            description
            hasEstimatedIssues
            id
            isDefaultPRPipeline
            isEpicPipeline
            name
            stage
            updatedAt
          }
        }
      }
    GRAPHQL
  end

  helpers do
    def extract_workspace_id(url)
      return nil unless url
      # Expected format: https://app.zenhub.com/workspaces/workspace-name-{id}/board
      parts = url.strip.split('/')
      puts "URL parts: #{parts.inspect}"  # Debug logging
      
      # Find the part that contains the workspace ID (24 hex chars)
      workspace_part = parts.find { |part| part.match?(/[0-9a-f]{24}/) }
      puts "Found workspace part: #{workspace_part}"  # Debug logging
      
      # Extract just the ID portion (24 hex chars)
      if workspace_part
        workspace_id = workspace_part.match(/([0-9a-f]{24})/)[1]
        puts "Extracted workspace_id: #{workspace_id}"  # Debug logging
        workspace_id
      end
    end
  end

  get '/' do
    erb :index
  end

  get '/pipelines' do
    workspace_id = extract_workspace_id(params[:workspace_url])
    puts "Input URL: #{params[:workspace_url]}"  # Debug logging
    
    if workspace_id.nil?
      status 400
      return "Could not extract workspace ID from URL. Please ensure you're using a valid ZenHub workspace URL."
    end
    result = Client.query(PipelinesQuery, variables: { workspaceId: workspace_id })
    @workspace = result.data.workspace if result.data
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
  <script src="https://cdn.tailwindcss.com"></script>
  <script>
    tailwind.config = {
      plugins: [
        tailwindcss.plugin.withOptions(function (options) {
          return function({ addBase, theme }) {
            addBase({
              '[type="text"]': {
                '--tw-shadow': '0 1px 2px 0 rgba(0, 0, 0, 0.05)',
                'box-shadow': 'var(--tw-ring-offset-shadow, 0 0 #0000), var(--tw-ring-shadow, 0 0 #0000), var(--tw-shadow)',
                'border-color': '#D1D5DB',
                'border-radius': '0.375rem',
                'border-width': '1px'
              }
            })
          }
        })
      ]
    }
  </script>
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
            <div class="bg-white shadow rounded-lg p-6">
              <h3 class="text-lg font-medium text-gray-900"><%= pipeline.name %></h3>
              <% if pipeline.description %>
                <p class="mt-1 text-sm text-gray-500"><%= pipeline.description %></p>
              <% end %>
              <dl class="mt-4 grid grid-cols-1 gap-x-4 gap-y-4 sm:grid-cols-2">
                <div>
                  <dt class="text-sm font-medium text-gray-500">Stage</dt>
                  <dd class="mt-1 text-sm text-gray-900"><%= pipeline.stage %></dd>
                </div>
                <div>
                  <dt class="text-sm font-medium text-gray-500">Created</dt>
                  <dd class="mt-1 text-sm text-gray-900"><%= Time.parse(pipeline.created_at).strftime("%Y-%m-%d") %></dd>
                </div>
                <div>
                  <dt class="text-sm font-medium text-gray-500">Type</dt>
                  <dd class="mt-1 text-sm text-gray-900">
                    <% if pipeline.is_epic_pipeline %>
                      Epic Pipeline
                    <% elsif pipeline.is_default_pr_pipeline %>
                      Default PR Pipeline
                    <% else %>
                      Standard Pipeline
                    <% end %>
                  </dd>
                </div>
                <div>
                  <dt class="text-sm font-medium text-gray-500">Has Estimated Issues</dt>
                  <dd class="mt-1 text-sm text-gray-900"><%= pipeline.has_estimated_issues ? 'Yes' : 'No' %></dd>
                </div>
              </dl>
            </div>
          <% end %>
        </div>
    </div>
  <% else %>
    <div class="sm:mx-auto sm:w-full sm:max-w-md">
      <h2 class="mt-6 text-center text-3xl font-bold tracking-tight text-gray-900">Enter your Workspace URL</h2>
      <p class="mt-2 text-center text-sm text-gray-600">
        Paste the full URL of your ZenHub workspace
      </p>
    </div>

    <div class="mt-8 sm:mx-auto sm:w-full sm:max-w-md">
      <div class="bg-white py-8 px-4 shadow sm:rounded-lg sm:px-10">
        <form class="space-y-6" method="GET" action="/pipelines">
          <div>
            <label for="workspace_url" class="block text-sm font-medium text-gray-700">Workspace URL</label>
            <div class="mt-1">
              <input id="workspace_url" name="workspace_url" type="text" required autofocus
                     placeholder="https://app.zenhub.com/workspaces/workspace-name-id"
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
