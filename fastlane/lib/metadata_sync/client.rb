module MetadataSync
  class Client
    class NoEditableVersionError < StandardError; end

    EDITABLE_VERSION_STATES = %w[
      PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED METADATA_REJECTED
      INVALID_BINARY WAITING_FOR_EXPORT_COMPLIANCE
    ].freeze
    LIVE_VERSION_STATE = "READY_FOR_SALE".freeze

    CAMEL_CASE_OVERRIDES = {
      "promotional_text" => "promotionalText",
      "marketing_url" => "marketingUrl",
      "support_url" => "supportUrl",
      "whats_new" => "whatsNew"
    }.freeze

    def initialize(transport:, app_id:, locale:)
      @transport = transport
      @app_id = app_id
      @locale = locale
    end

    def fetch_app_info
      loc = app_info_localization
      { "name" => loc.dig("attributes", "name"), "subtitle" => loc.dig("attributes", "subtitle") }
    end

    def fetch_version_info
      version = editable_version || live_version
      loc = version_localization(version)
      return {} unless loc

      attrs = loc["attributes"]
      {
        "description" => attrs["description"],
        "keywords" => attrs["keywords"],
        "promotional_text" => attrs["promotionalText"],
        "marketing_url" => attrs["marketingUrl"],
        "support_url" => attrs["supportUrl"],
        "whats_new" => attrs["whatsNew"]
      }
    end

    def push_app_info(changes)
      return if changes.empty?

      loc = app_info_localization
      @transport.patch(
        "/v1/appInfoLocalizations/#{loc['id']}",
        patch_body("appInfoLocalizations", loc["id"], camelize_keys(changes))
      )
    end

    def push_version_info(changes)
      return if changes.empty?

      requires_editable = changes.keys.any? { |k| k != "promotional_text" }
      version = requires_editable ? editable_version : (editable_version || live_version)
      if version.nil?
        raise NoEditableVersionError,
              "No editable App Store version found for app #{@app_id} — start a new version " \
              "in App Store Connect before syncing #{changes.keys.join(', ')}."
      end

      loc = version_localization(version)
      @transport.patch(
        "/v1/appStoreVersionLocalizations/#{loc['id']}",
        patch_body("appStoreVersionLocalizations", loc["id"], camelize_keys(changes))
      )
    end

    private

    def camelize_keys(hash)
      hash.each_with_object({}) { |(k, v), out| out[CAMEL_CASE_OVERRIDES.fetch(k, k)] = v }
    end

    def patch_body(type, id, attributes)
      { "data" => { "type" => type, "id" => id, "attributes" => attributes } }
    end

    def app_info_localization
      infos = @transport.get("/v1/apps/#{@app_id}/appInfos")["data"]
      primary = infos.find { |i| i.dig("attributes", "appStoreState") != LIVE_VERSION_STATE } || infos.first
      raise "App #{@app_id} has no appInfos" unless primary

      locs = @transport.get("/v1/appInfos/#{primary['id']}/appInfoLocalizations")["data"]
      locs.find { |l| l.dig("attributes", "locale") == @locale } ||
        raise("No appInfoLocalization for locale #{@locale} on app #{@app_id}")
    end

    def versions
      @versions ||= @transport.get("/v1/apps/#{@app_id}/appStoreVersions")["data"]
    end

    def editable_version
      versions.find { |v| EDITABLE_VERSION_STATES.include?(v.dig("attributes", "appStoreState")) }
    end

    def live_version
      versions.find { |v| v.dig("attributes", "appStoreState") == LIVE_VERSION_STATE }
    end

    def version_localization(version)
      return nil unless version

      locs = @transport.get("/v1/appStoreVersions/#{version['id']}/appStoreVersionLocalizations")["data"]
      locs.find { |l| l.dig("attributes", "locale") == @locale }
    end
  end
end
