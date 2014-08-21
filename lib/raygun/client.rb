module Raygun
  # client for the Raygun REST APIv1
  # as per http://raygun.io/raygun-providers/rest-json-api?v=1
  class Client

    ENV_IP_ADDRESS_KEYS = %w(action_dispatch.remote_ip raygun.remote_ip REMOTE_ADDR)

    include HTTParty

    base_uri "https://api.raygun.io/"

    http_proxy proxy_settings[:host], proxy_settings[:port] if use_proxy?

    def initialize
      @api_key = require_api_key!

      @headers = {
        "X-ApiKey" => @api_key
      }
    end

    def require_api_key!
      Raygun.configuration.api_key || raise(ApiKeyRequired.new("Please specify your Raygun API key using Raygun#setup (find yours at https://app.raygun.io)"))
    end

    def track_exception(exception_instance, env = {})
      create_entry(build_payload_hash(exception_instance, env))
    end

    private

      def client_details
        {
          name:      Raygun::CLIENT_NAME,
          version:   Raygun::VERSION,
          clientUrl: Raygun::CLIENT_URL
        }
      end

      def self.proxy_settings
        {
          host: Raygun.configuration.proxy_host,
          port: Raygun.configuration.proxy_port || 80
        }
      end

      def self.use_proxy?
        Raygun.configuration.proxy_host.present?
      end

      def error_details(exception)
        {
          className:  exception.class.to_s,
          message:    exception.message.encode('UTF-16', :undef => :replace, :invalid => :replace).encode('UTF-8'),
          stackTrace: (exception.backtrace || []).map { |line| stack_trace_for(line) }
        }
      end

      def stack_trace_for(line)
        # see http://www.ruby-doc.org/core-2.0/Exception.html#method-i-backtrace
        file_name, line_number, method = line.split(":")
        {
          lineNumber: line_number,
          fileName:   file_name,
          methodName: method ? method.gsub(/^in `(.*?)'$/, "\\1") : "(none)"
        }
      end

      def hostname
        Socket.gethostname
      end

      def version
        Raygun.configuration.version
      end

      def user_information(env)
        env["raygun.affected_user"]
      end

      def affected_user_present?(env)
        !!env["raygun.affected_user"]
      end

      def request_information(env)
        return {} if env.nil? || env.empty?

        {
          hostName:    env["SERVER_NAME"],
          url:         env["PATH_INFO"],
          httpMethod:  env["REQUEST_METHOD"],
          iPAddress:   "#{ip_address_from(env)}",
          queryString: Rack::Utils.parse_nested_query(env["QUERY_STRING"]),
          form:        form_data(env),
          headers:     headers(env),
          rawData:     []
        }
      end

      def headers(rack_env)
        rack_env.select { |k, v| k.to_s.start_with?("HTTP_") }.inject({}) do |hsh, (k, v)|
          hsh[normalize_raygun_header_key(k)] = v
          hsh
        end
      end

      def normalize_raygun_header_key(key)
        key.sub(/^HTTP_/, '')
           .sub(/_/, ' ')
           .split.map(&:capitalize).join(' ')
           .sub(/ /, '-')
      end

      def form_data(rack_env)
        request = Rack::Request.new(rack_env)
        if request.form_data?
          filter_params(request.params, rack_env["action_dispatch.parameter_filter"])
        end
      end

      # see http://raygun.io/raygun-providers/rest-json-api?v=1
      def build_payload_hash(exception_instance, env = {})
        custom_data = env.delete(:custom_data) || {}

        error_details = {
            machineName:    hostname,
            version:        version,
            client:         client_details,
            error:          error_details(exception_instance),
            userCustomData: Raygun.configuration.custom_data.merge(custom_data),
            request:        request_information(env)
        }

        error_details.merge!(user: user_information(env)) if affected_user_present?(env)

        {
          occurredOn: Time.now.utc.iso8601,
          details:    error_details
        }
      end

      def create_entry(payload_hash)
        self.class.post("/entries", headers: @headers, body: JSON.generate(payload_hash))
      end

      def filter_params(params_hash, extra_filter_keys = nil)
        filter_keys = (Array(extra_filter_keys) + Raygun.configuration.filter_parameters).map(&:to_s)

        # Recursive filtering of (nested) hashes
        params_hash.inject({}) do |result, (k, v)|
          result[k] = case v
          when Hash
            filter_params(v, extra_filter_keys)
          else
            filter_keys.include?(k) ? "[FILTERED]" : v
          end
          result
        end
      end

      def ip_address_from(env_hash)
        ENV_IP_ADDRESS_KEYS.each do |key_to_try|
          return env_hash[key_to_try] unless env_hash[key_to_try].nil? || env_hash[key_to_try] == ""
        end
      end

  end
end
