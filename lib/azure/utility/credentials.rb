# frozen_string_literal: true

require 'io/console'
require 'net/http'
require 'uri'
require 'json'
require 'securerandom'
require 'time'
require 'logger'
require 'mixlib/cli'

module Azure
  module Utility
    #
    # Options
    #
    class Options
      include Mixlib::CLI

      option :username,
             short: '-u',
             long: '--username USERNAME',
             description: 'Enter the username (must be an Azure AD user)',
             required: false

      option :password,
             short: '-p',
             long: '--password PASSWORD',
             description: 'Enter the password for the Azure AD user',
             required: false

      option :subscription_id,
             short: '-s',
             long: '--subscription ID',
             description: 'Enter the Subscription ID to work against (default: process all subscriptions within the Azure tenant)',
             required: false,
             default: nil

      option :role,
             short: '-r',
             long: '--role ROLENAME',
             description: 'Enter the built-in Azure role to add the service principal to on your subscription (default: Contributor)',
             in: %w[Contributor Owner],
             default: 'Contributor',
             required: false

      option :type,
             short: '-t',
             long: '--type OUTPUTTYPE',
             description: 'Set the output type (default: chef)',
             in: %w[chef puppet terraform generic],
             required: false,
             default: 'chef'

      option :log_level,
             short: '-l',
             long: '--log_level LEVEL',
             description: 'Set the log level (debug, info, warn, error, fatal)',
             default: :info,
             required: false,
             in: %w[debug info warn error fatal],
             proc: proc { |l| l.to_sym }

      option :output_file,
             short: '-o',
             long: '--output FILENAME',
             description: 'Enter the filename to save the credentials to',
             default: './credentials',
             required: false

      option :out_to_screen,
             short: '-v',
             long: '--verbose',
             description: 'Display the credentials in STDOUT after creation? (warning: will contain secrets)',
             default: false,
             required: false

      option :help,
             short: '-h',
             long: '--help',
             description: 'Show this message',
             on: :tail,
             boolean: true,
             show_options: true,
             exit: 0
    end

    #
    # Logger
    #
    class CustomLogger
      def self.log
        if @logger.nil?
          cli = Options.new
          cli.parse_options
          @logger = Logger.new STDOUT
          @logger.level = logger_level_for(cli.config[:log_level])
          @logger.formatter = proc do |severity, datetime, _progname, msg|
            "#{severity} [#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] #{msg}\n"
          end
        end
        @logger
      end

      def self.logger_level_for(sym)
        case sym
        when :debug
          Logger::DEBUG
        when :info
          Logger::INFO
        when :warn
          Logger::WARN
        when :error
          Logger::ERROR
        when :fatal
          Logger::FATAL
        end
      end
    end

    #
    # Credentials
    #
    class Credentials
      AZURE_SERVICE_PRINCIPAL = '1950a258-227b-4e31-a9cf-717495945fc2'
      CONFIG_PATH = "#{ENV['HOME']}/.azure/credentials"

      def initialize
        cli = Options.new
        cli.parse_options
        CustomLogger.log.debug "Command line options: #{cli.config.inspect}"

        username = cli.config[:username] || username_stdin
        password = cli.config[:password] || password_stdin

        # Get Bearer token for user and pass through to main method
        token = azure_authenticate(username, password)
        if token.nil?
          error_message = 'Unable to acquire token from Azure AD provider.'
          CustomLogger.log.error error_message
          raise error_message
        end
        created_credentials = create_all_objects(token, cli.config)
        CustomLogger.log.debug "Credential details: #{created_credentials.inspect}"
        create_file(created_credentials, cli.config)
        CustomLogger.log.info 'Done!'
      end

      def username_stdin
        print 'Enter your Azure AD username (user@domain.com): '
        STDIN.gets.chomp
      end

      def password_stdin
        print 'Enter your password: '
        STDIN.noecho(&:gets).chomp
      end

      def create_file(created_credentials, config)
        file_name = config[:output_file] || './credentials'
        file_name_expanded = File.expand_path(file_name)
        CustomLogger.log.info "Creating credentials file at #{file_name_expanded}"
        output = ''

        style = config[:type] || 'chef'
        case style
        when 'chef' # ref: https://github.com/pendrica/chef-provisioning-azurerm#configuration
          created_credentials.each do |s|
            subscription_template = <<~CHEFEOH
              [#{s[:subscription_id]}]
              client_id = "#{s[:client_id]}"
              client_secret = "#{s[:client_secret]}"
              tenant_id = "#{s[:tenant_id]}"

            CHEFEOH
            output += subscription_template
          end
        when 'terraform' # ref: https://www.terraform.io/docs/providers/azurerm/index.html
          created_credentials.each do |s|
            subscription_template = <<~TFEOH
              provider "azurerm" {
                subscription_id = "#{s[:subscription_id]}"
                client_id       = "#{s[:client_id]}"
                client_secret   = "#{s[:client_secret]}"
                tenant_id       = "#{s[:tenant_id]}"
              }

            TFEOH
            output += subscription_template
          end
        when 'puppet' # ref: https://github.com/puppetlabs/puppetlabs-azure#installing-the-azure-module
          created_credentials.each do |s|
            subscription_template = <<~PPEOH
              azure: {
                subscription_id: "#{s[:subscription_id]}"
                tenant_id: "#{s[:tenant_id]}"
                client_id: "#{s[:client_id]}"
                client_secret: "#{s[:client_secret]}"
              }

            PPEOH
            output += subscription_template
          end
        else # generic credentials output
          created_credentials.each do |s|
            subscription_template = <<~GENERICEOH
              azure_subscription_id = "#{s[:subscription_id]}"
              azure_tenant_id = "#{s[:tenant_id]}"
              azure_client_id = "#{s[:client_id]}"
              azure_client_secret = "#{s[:client_secret]}"

            GENERICEOH
            output += subscription_template
          end
        end
        File.open(file_name_expanded, 'w') do |file|
          file.write(output)
        end
        puts output if config[:out_to_screen]
      end

      def create_all_objects(token, config)
        tenant_id = get_tenant_id(token).first['tenantId']
        subscriptions = Array(config[:subscription_id])
        subscriptions = get_subscriptions(token) if subscriptions.empty?
        identifier = SecureRandom.hex(2)
        credentials = []
        subscriptions.each do |subscription|
          new_application_name = "azure_#{identifier}_#{subscription}"
          new_client_secret = SecureRandom.urlsafe_base64(16, true)
          application_id = create_application(tenant_id, token, new_application_name, new_client_secret)['appId']
          service_principal_object_id = create_service_principal(tenant_id, token, application_id)['objectId']
          role_name = config[:role] || 'Contributor'
          role_definition_id = get_role_definition(subscription, token, role_name).first['id']
          success = false
          counter = 0
          until success || counter > 5
            counter += 1
            CustomLogger.log.info "Waiting for service principal to be available in directory (retry #{counter})"
            sleep 2
            assigned_role = assign_service_principal_to_role_id(subscription, token, service_principal_object_id, role_definition_id)
            success = true unless assigned_role['error']
          end
          raise 'Failed to assign Service Principal to Role' unless success
          CustomLogger.log.info "Assigned service principal to role #{role_name} in subscription #{subscription}"
          new_credentials = {}
          new_credentials[:subscription_id] = subscription
          new_credentials[:client_id] = application_id
          new_credentials[:client_secret] = new_client_secret
          new_credentials[:tenant_id] = tenant_id
          credentials.push(new_credentials)
        end
        credentials
      end

      def get_subscriptions(token)
        CustomLogger.log.info 'Retrieving subscriptions info'
        subscriptions = []
        subscriptions_call = azure_call(:get, 'https://management.azure.com/subscriptions?api-version=2015-01-01', nil, token)
        subscriptions_call['value'].each do |subscription|
          subscriptions.push subscription['subscriptionId']
        end
        CustomLogger.log.debug "SubscriptionIDs returned: #{subscriptions.inspect}"
        subscriptions
      end

      def get_tenant_id(token)
        CustomLogger.log.info 'Retrieving tenant info'
        tenants = azure_call(:get, 'https://management.azure.com/tenants?api-version=2015-01-01', nil, token)
        tenants['value']
      end

      def create_application(tenant_id, token, new_application_name, new_client_secret)
        CustomLogger.log.info "Creating application #{new_application_name} in tenant #{tenant_id}"
        url = "https://graph.windows.net/#{tenant_id}/applications?api-version=1.42-previewInternal"
        payload_json = <<-JSONEOH
        {
            "availableToOtherTenants": false,
            "displayName": "#{new_application_name}",
            "homepage": "https://management.core.windows.net",
            "identifierUris": [
                "https://#{tenant_id}/#{new_application_name}"
            ],
            "passwordCredentials": [
                {
                "startDate": "#{Time.now.utc.iso8601}",
                "endDate": "#{(Time.now + (24 * 60 * 60 * 365 * 10)).utc.iso8601}",
                "keyId": "#{SecureRandom.uuid}",
                "value": "#{new_client_secret}"
                }
            ]
        }
        JSONEOH
        azure_call(:post, url, payload_json, token)
      end

      def create_service_principal(tenant_id, token, application_id)
        CustomLogger.log.info 'Creating service principal for application'
        url = "https://graph.windows.net/#{tenant_id}/servicePrincipals?api-version=1.42-previewInternal"
        payload_json = <<-PAYLOADEOH
        {
            "appId": "#{application_id}",
            "accountEnabled": true
        }
        PAYLOADEOH
        azure_call(:post, url, payload_json, token)
      end

      def assign_service_principal_to_role_id(subscription_id, token, service_principal_object_id, role_definition_id)
        CustomLogger.log.info 'Attempting to assign service principal to role'
        url = "https://management.azure.com/subscriptions/#{subscription_id}/providers/Microsoft.Authorization/roleAssignments/#{service_principal_object_id}?api-version=2015-07-01"
        payload_json = <<-PAYLOADEOH
        {
            "properties": {
                "roleDefinitionId": "#{role_definition_id}",
                "principalId": "#{service_principal_object_id}"
            }
        }
        PAYLOADEOH
        azure_call(:put, url, payload_json, token)
      end

      def get_role_definition(tenant_id, token, role_name)
        role_definitions = azure_call(:get, "https://management.azure.com/subscriptions/#{tenant_id}/providers/Microsoft.Authorization/roleDefinitions?$filter=roleName%20eq%20\'#{role_name}\'&api-version=2015-07-01", nil, token)
        role_definitions['value']
      end

      def azure_authenticate(username, password)
        CustomLogger.log.info 'Authenticating to Azure Active Directory'
        url = 'https://login.windows.net/Common/oauth2/token'
        data = "resource=https%3A%2F%2Fmanagement.core.windows.net%2F&client_id=#{AZURE_SERVICE_PRINCIPAL}" \
          "&grant_type=password&username=#{username}&scope=openid&password=#{password}"
        response = http_post(url, data)
        JSON.parse(response.body)['access_token']
      end

      def http_post(url, data)
        uri = URI(url)
        response = nil
        Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
          request = Net::HTTP::Post.new uri
          CustomLogger.log.debug "Request: #{request.uri} (#{request.method}) #{data}"
          request.body = data
          response = http.request request
          CustomLogger.log.debug "Response: #{response.body}"
        end
        response
      end

      def azure_call(method, url, data, token)
        uri = URI(url)
        response = nil
        Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
          case method
          when :put
            request = Net::HTTP::Put.new uri
          when :delete
            request = Net::HTTP::Delete.new uri
          when :get
            request = Net::HTTP::Get.new uri
          when :post
            request = Net::HTTP::Post.new uri
          when :patch
            request = Net::HTTP::Patch.new uri
          end
          request.body = data
          request['Authorization'] = "Bearer #{token}"
          request['Content-Type'] = 'application/json'
          CustomLogger.log.debug "Request: #{request.uri} (#{method}) #{data}"
          response = http.request request
          CustomLogger.log.debug "Response: #{response.body}"
        end
        JSON.parse(response.body) unless response.nil?
      end
    end
  end
end
