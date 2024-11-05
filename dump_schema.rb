require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'graphql-client'
end

require 'graphql/client'
require 'graphql/client/http'

class ZenhubHTTP < GraphQL::Client::HTTP
  def headers(context)
    { "Authorization": "Bearer #{ENV['ZENHUB_TOKEN']}" }
  end
end

# Ensure ZENHUB_TOKEN is set
unless ENV['ZENHUB_TOKEN']
  puts "ERROR: ZENHUB_TOKEN environment variable is required"
  exit 1
end

begin
  http = ZenhubHTTP.new('https://api.zenhub.com/public/graphql')
  
  # Dump schema to file
  GraphQL::Client.dump_schema(http, "zenhub_schema.json")
  
  puts "Schema successfully dumped to schema.json"
rescue => e
  puts "Error dumping schema: #{e.message}"
  puts e.backtrace
  exit 1
end
