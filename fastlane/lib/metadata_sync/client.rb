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
      loc = app_info_localization(require_editable: false)
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

      loc = app_info_localization(require_editable: true)
      @transport.patch(
        "/v1/appInfoLocalizations/#{loc['id']}",
        patch_body("appInfoLocalizations", loc["id"], camelize_keys(changes))
      )
    end

    def push_version_info(changes)
      return if changes.empty?

      _version, loc = resolve_version_target!(changes)
      @transport.patch(
        "/v1/appStoreVersionLocalizations/#{loc['id']}",
        patch_body("appStoreVersionLocalizations", loc["id"], camelize_keys(changes))
      )
    end

    # Resolves (and validates) the App Store version + localization that
    # `changes` would be pushed to, WITHOUT issuing any PATCH. Raises the same
    # errors push_version_info would raise if the push were attempted.
    #
    # Callers that need to issue multiple mutating calls (e.g. push_app_info
    # followed by push_version_info) should call this first for any
    # version_info changes and let it raise before any PATCH fires, so a
    # missing editable version can never result in a partial push.
    #
    # promotionalText gets no special treatment here: the original plan
    # assumed Apple lets you edit it on the live (READY_FOR_SALE) version
    # without a new one, but that's confirmed wrong against a real app in
    # that state — nothing on a READY_FOR_SALE version is editable via the
    # API, promotionalText included. Every version_info field, this one too,
    # requires an actual editable version.
    def resolve_version_target!(changes)
      version = editable_version
      if version.nil?
        raise NoEditableVersionError,
              "No editable App Store version found for app #{@app_id} — start a new version " \
              "in App Store Connect before syncing #{changes.keys.join(', ')}."
      end

      loc = version_localization(version)
      if loc.nil?
        raise "No appStoreVersionLocalization for locale #{@locale} on app #{@app_id} version #{version['id']}"
      end

      [version, loc]
    end

    private

    def camelize_keys(hash)
      hash.each_with_object({}) { |(k, v), out| out[CAMEL_CASE_OVERRIDES.fetch(k, k)] = v }
    end

    def patch_body(type, id, attributes)
      { "data" => { "type" => type, "id" => id, "attributes" => attributes } }
    end

    # All appStoreState values we ever look for (editable_version/live_version).
    # Filtering server-side on exactly these means we never depend on landing
    # on the right page of an app's full version history.
    RELEVANT_VERSION_STATES = (EDITABLE_VERSION_STATES + [LIVE_VERSION_STATE]).freeze

    # Like the version-scoped fields, a read never needs an editable appInfo
    # (falls back to the live one so metadata_pull still works against a
    # shipped app with no open version) but a write does: an app with no
    # non-live appInfo has nothing name/subtitle can be PATCHed onto, and
    # attempting it anyway would just get rejected by Apple with an opaque
    # error instead of the clear, actionable one this tool aims for.
    def app_info_localization(require_editable:)
      infos = @transport.get("/v1/apps/#{@app_id}/appInfos")["data"]
      raise "App #{@app_id} has no appInfos" if infos.empty?

      primary = infos.find { |i| i.dig("attributes", "appStoreState") != LIVE_VERSION_STATE }
      if primary.nil?
        if require_editable
          raise NoEditableVersionError,
                "No editable App Info found for app #{@app_id} — every appInfo is #{LIVE_VERSION_STATE}. " \
                "Start a new App Store version in App Store Connect before syncing name/subtitle."
        end
        primary = infos.first
      end

      locs = @transport.get("/v1/appInfos/#{primary['id']}/appInfoLocalizations?filter[locale]=#{@locale}")["data"]
      locs.find { |l| l.dig("attributes", "locale") == @locale } ||
        raise("No appInfoLocalization for locale #{@locale} on app #{@app_id}")
    end

    def versions
      # GET /v1/apps/{id}/appStoreVersions returns an unfiltered default page
      # of 50 with no pagination follow-up. An app with a long release
      # history can have its editable (or even live) version fall off page
      # one. Filter server-side to only the states we ever care about, and
      # ask for a generous limit as a second line of defense.
      @versions ||= @transport.get(
        "/v1/apps/#{@app_id}/appStoreVersions?filter[appStoreState]=#{RELEVANT_VERSION_STATES.join(',')}&limit=200"
      )["data"]
    end

    def editable_version
      versions.find { |v| EDITABLE_VERSION_STATES.include?(v.dig("attributes", "appStoreState")) }
    end

    def live_version
      versions.find { |v| v.dig("attributes", "appStoreState") == LIVE_VERSION_STATE }
    end

    def version_localization(version)
      return nil unless version

      locs = @transport.get(
        "/v1/appStoreVersions/#{version['id']}/appStoreVersionLocalizations?filter[locale]=#{@locale}"
      )["data"]
      locs.find { |l| l.dig("attributes", "locale") == @locale }
    end
  end
end
