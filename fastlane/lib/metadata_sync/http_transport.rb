require "net/http"
require "json"
require "uri"

module MetadataSync
  class HttpTransport
    DEFAULT_BASE_URL = "https://api.appstoreconnect.apple.com".freeze

    def initialize(token:, base_url: DEFAULT_BASE_URL)
      @token = token
      @base_url = base_url
    end

    def get(path)
      request(Net::HTTP::Get, path)
    end

    def patch(path, body)
      request(Net::HTTP::Patch, path, body)
    end

    private

    def request(klass, path, body = nil)
      uri = URI.join(@base_url, path)
      req = klass.new(uri)
      req["Authorization"] = "Bearer #{@token}"
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body) if body

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(req) }
      unless response.code.to_i.between?(200, 299)
        raise "App Store Connect API error #{response.code} for #{path}: #{response.body}"
      end

      response.body.empty? ? {} : JSON.parse(response.body)
    end
  end
end
