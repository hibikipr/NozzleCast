module MetadataSync
  class Client
    class NoEditableVersionError < StandardError; end
    class NoVersionFoundError < StandardError; end

    # The complete AppStoreVersionState enum, per Apple's own reference
    # (https://developer.apple.com/documentation/appstoreconnectapi/appstoreversionstate),
    # for the record as of this writing:
    #   ACCEPTED, DEVELOPER_REMOVED_FROM_SALE, DEVELOPER_REJECTED, IN_REVIEW,
    #   INVALID_BINARY, METADATA_REJECTED, PENDING_APPLE_RELEASE,
    #   PENDING_CONTRACT, PENDING_DEVELOPER_RELEASE, PREPARE_FOR_SUBMISSION,
    #   PREORDER_READY_FOR_SALE, PROCESSING_FOR_APP_STORE, READY_FOR_REVIEW,
    #   READY_FOR_SALE, REJECTED, REMOVED_FROM_SALE,
    #   WAITING_FOR_EXPORT_COMPLIANCE, WAITING_FOR_REVIEW,
    #   REPLACED_WITH_NEW_VERSION, NOT_APPLICABLE.
    # NOTE: AppStoreVersionState itself is DEPRECATED in favor of the newer
    # AppVersionState (App Store Connect API 3.3+), which renames
    # READY_FOR_SALE -> READY_FOR_DISTRIBUTION and PROCESSING_FOR_APP_STORE ->
    # PROCESSING_FOR_DISTRIBUTION, and drops PENDING_CONTRACT,
    # PREORDER_READY_FOR_SALE, DEVELOPER_REMOVED_FROM_SALE,
    # REMOVED_FROM_SALE, and NOT_APPLICABLE entirely. As of this writing the
    # live `GET /v1/apps/{id}/appStoreVersions` endpoint this Client actually
    # calls still returns the old (deprecated) values -- confirmed
    # empirically against a real live app, which resolved as READY_FOR_SALE,
    # not READY_FOR_DISTRIBUTION. If Apple ever migrates that endpoint's
    # returned values to the new names, every state string below (and the
    # LIVE_VERSION_STATE constant) needs updating to match.
    #
    # Below this point we only classify the states we have SOME basis for:
    # states that logically must permit edits to let a developer fix and
    # resubmit (EDITABLE_VERSION_STATES), one state confirmed directly
    # against a real app to be readable-but-not-necessarily-writable
    # (WAITING_FOR_REVIEW), and states in the same "submitted, awaiting
    # review or release" family as that confirmed one, reasoned by analogy
    # but not individually tested (the rest of READABLE_ONLY_VERSION_STATES).
    # Everything else -- PENDING_CONTRACT, PREORDER_READY_FOR_SALE,
    # DEVELOPER_REMOVED_FROM_SALE, REMOVED_FROM_SALE,
    # REPLACED_WITH_NEW_VERSION, NOT_APPLICABLE -- is deliberately
    # unclassified rather than guessed at. An app whose ONLY version sits in
    # one of those states resolves to no version at all here, which
    # `fetch_version_info` now treats as a loud, actionable failure (see
    # NoVersionFoundError below) instead of silently returning {} and letting
    # metadata_pull overwrite a repo's already-seeded metadata with nothing.

    EDITABLE_VERSION_STATES = %w[
      PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED METADATA_REJECTED
      INVALID_BINARY WAITING_FOR_EXPORT_COMPLIANCE REJECTED
    ].freeze
    LIVE_VERSION_STATE = "READY_FOR_SALE".freeze

    # WAITING_FOR_REVIEW confirmed directly against a real app (NozzleCast):
    # Apple's own App Store Connect UI says "You can edit some information
    # while your version is waiting for review" -- neither fully editable
    # (EDITABLE_VERSION_STATES) nor fully locked (LIVE_VERSION_STATE). The
    # other six are reasoned by analogy, not individually confirmed, as the
    # same "somewhere in the review/release pipeline" family -- with one
    # caveat: READY_FOR_REVIEW is queued but likely still pre-submission and
    # possibly still writable in practice, unlike the rest. Classifying it
    # read-only here is the conservative choice (base treated it as nothing
    # at all), not a confirmed fact -- worth re-testing against a real app in
    # that specific state. Reads fall back to any of these; push still
    # always requires a genuinely editable version and raises rather than
    # guessing which fields, if any, would actually PATCH successfully here.
    READABLE_ONLY_VERSION_STATES = %w[
      WAITING_FOR_REVIEW IN_REVIEW READY_FOR_REVIEW ACCEPTED
      PENDING_DEVELOPER_RELEASE PENDING_APPLE_RELEASE PROCESSING_FOR_APP_STORE
    ].freeze

    CAMEL_CASE_OVERRIDES = {
      "promotional_text" => "promotionalText",
      "marketing_url" => "marketingUrl",
      "support_url" => "supportUrl",
      "whats_new" => "whatsNew"
    }.freeze

    # The App Store version the most recent fetch_version_info actually read
    # from, as {"version" => "1.3.0", "state" => "PREPARE_FOR_SUBMISSION"}.
    # A read resolves editable -> review-pipeline -> live, so it is NOT
    # necessarily the version that is live on the App Store; metadata_pull
    # reports this so pulling from a draft is visible rather than silent.
    attr_reader :source_version

    def initialize(transport:, app_id:, locale:)
      @transport = transport
      @app_id = app_id
      @locale = locale
      @source_version = nil
    end

    def fetch_app_info
      loc = app_info_localization(require_editable: false)
      { "name" => loc.dig("attributes", "name"), "subtitle" => loc.dig("attributes", "subtitle") }
    end

    def fetch_version_info
      version = editable_version || readable_only_version || live_version
      if version.nil?
        raise NoVersionFoundError,
              "No App Store version found for app #{@app_id} in any recognized state " \
              "(editable, review/release-pipeline, or live). Check the app's actual state " \
              "in App Store Connect -- metadata_pull refuses to overwrite the repo's seeded " \
              "metadata with an empty result."
      end

      loc = version_localization(version)
      if loc.nil?
        raise NoVersionFoundError,
              "App #{@app_id}'s resolved version (#{version['id']}) has no " \
              "appStoreVersionLocalization for locale #{@locale}."
      end

      @source_version = {
        "version" => version.dig("attributes", "versionString"),
        "state" => version.dig("attributes", "appStoreState")
      }

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

    # All appStoreState values we ever look for (editable_version/
    # readable_only_version/live_version). Filtering server-side on exactly
    # these means we never depend on landing on the right page of an app's
    # full version history.
    RELEVANT_VERSION_STATES = (EDITABLE_VERSION_STATES + READABLE_ONLY_VERSION_STATES + [LIVE_VERSION_STATE]).freeze

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

    def readable_only_version
      versions.find { |v| READABLE_ONLY_VERSION_STATES.include?(v.dig("attributes", "appStoreState")) }
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
