require 'octokit'

module Github
  # Class to interact with GitHub Projects
  class Project
    attr_accessor :token, :organization, :number

    def initialize(token:, organization:, number:)
      @token = token
      @organization = organization
      @number = number
    end

    # def sprints_with_issues
    #   sprints.map { |sprint| [sprint[:title], issues_by_sprint(sprint[:title])] }.to_h
    # end

    def sprints
      @sprints ||=
        issues
        .map { |issue| issue[:fieldValues][:nodes].select { |node| node[:field] && node[:field][:name] == 'Sprint' } }
        .flatten
        .uniq { |node| [node[:field][:name], node[:startDate]] }
        .map do |sprint|
          {
            title: sprint[:title],
            start_date: sprint[:startDate],
            duration: sprint[:duration],
            iteration_id: sprint[:iterationId]
          }
        end
        .sort_by { |sprint| sprint[:start_date] }
    end

    def active_sprints
      sprints.select do |sprint|
        next unless sprint[:start_date]

        Date.parse(sprint[:start_date]) <= Date.today
      end
    end

    def issues_by_sprint(sprint_title)
      sprint_issues = []

      issues.each do |issue|
        issue[:fieldValues][:nodes].each do |node|
          if node[:field] && node[:field][:name] == "Sprint"
            next unless node[:title] == sprint_title

            sprint_issues << issue.to_h
          end
        end
      end

      sprint_issues
    end

    def issues
      @issues ||= begin
        $logger.info "Loading GitHub Project #{organization}/##{number}..."
        items = []
        has_next_page = true
        cursor = nil

        while has_next_page
          response = query(build_query(cursor))
          project_items = response.dig(:data, :node, :items, :nodes)
          items.concat(project_items)

          page_info = response.dig(:data, :node, :items, :pageInfo)
          has_next_page = page_info[:hasNextPage]
          cursor = page_info[:endCursor]
        end

        items
      end
    end

    def build_query(cursor = nil)
      after_cursor = cursor ? %(, after: "#{cursor}") : ''
      %{
        query {
          node(id: "#{node_id}") {
            ... on ProjectV2 {
              items(first: 100#{after_cursor}) {
                nodes {
                  id
                  fieldValues(first: 10) {
                    nodes {
                      ... on ProjectV2ItemFieldTextValue {
                        text
                        field {
                          ... on ProjectV2FieldCommon {
                            name
                          }
                        }
                      }
                      ... on ProjectV2ItemFieldNumberValue {
                        number
                        field {
                          ... on ProjectV2FieldCommon {
                            name
                          }
                        }
                      }
                      ... on ProjectV2ItemFieldDateValue {
                        date
                        field {
                          ... on ProjectV2FieldCommon {
                            name
                          }
                        }
                      }
                      ... on ProjectV2ItemFieldSingleSelectValue {
                        name
                        field {
                          ... on ProjectV2FieldCommon {
                            name
                          }
                        }
                      }
                      ... on ProjectV2ItemFieldIterationValue {
                        title
                        iterationId
                        startDate
                        duration
                        field {
                          ... on ProjectV2FieldCommon {
                            name
                          }
                        }
                      }
                    }
                  }
                  content {
                    ... on DraftIssue {
                      title
                      body
                    }
                    ... on Issue {
                      title
                      number
                      state
                      url
                      closedAt
                      createdAt
                      assignees(first: 10) {
                        nodes {
                          login
                        }
                      }
                      labels(first: 20) {
                        nodes {
                          name
                        }
                      }
                    }
                    ... on PullRequest {
                      title
                      number
                      state
                      url
                      closedAt
                      createdAt
                      assignees(first: 10) {
                        nodes {
                          login
                        }
                      }
                      labels(first: 20) {
                        nodes {
                          name
                        }
                      }
                    }
                  }
                }
                pageInfo {
                  hasNextPage
                  endCursor
                }
              }
            }
          }
        }
      }
    end

    def node_id
      @node_id ||= query(
        %{query{organization(login: "#{organization}") {projectV2(number: #{number}){id}}}}
      )[:data][:organization][:projectV2][:id]
    end

    def info
      @project_info ||= query(
        %{query{
          organization(login: "#{organization}") {
            projectV2(number: #{number}) {
              id
              number
              public
              url
              title
              closed
            }
          }
        }}
      )[:data][:organization][:projectV2]
    end

    def query(query)
      handle_rate_limit
      response = client.post '/graphql', { query: }.to_json
      p response if ENV['DEBUG']
      if response[:errors]
        $logger.error "Query: #{query}"
        $logger.error(response[:errors].map { |error| error[:message] })
        raise 'GraphQL Error'
      end
      response
    end

    def client
      @client ||= Octokit::Client.new(access_token: token)
    end

    private

    def handle_rate_limit
      rate_limit = client.rate_limit
      return unless rate_limit.remaining < 10

      sleep_time = [rate_limit.resets_in, 0].max
      $logger.info "Rate limit almost exceeded, sleeping for #{sleep_time} seconds..."
      sleep sleep_time
    end
  end
end
