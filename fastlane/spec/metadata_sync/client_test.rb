require "minitest/autorun"
require "json"
require "tmpdir"
require "metadata_sync/client"

class FakeTransport
  def initialize(fixtures)
    @fixtures = fixtures
    @patches = []
  end

  attr_reader :patches

  def get(path)
    fixture = @fixtures.fetch(path) { raise "no fixture stubbed for GET #{path}" }
    JSON.parse(File.read(fixture))
  end

  def patch(path, body)
    @patches << { path: path, body: body }
    {}
  end
end

class ClientTest < Minitest::Test
  FIXTURES_DIR = File.join(__dir__, "..", "fixtures")

  # Must mirror the exact query strings Client builds (filter[appStoreState]
  # for the versions GET, filter[locale] for both localization GETs -- see
  # I2). FakeTransport matches on the exact path string.
  RELEVANT_VERSION_STATES = "PREPARE_FOR_SUBMISSION,DEVELOPER_REJECTED,METADATA_REJECTED," \
                             "INVALID_BINARY,WAITING_FOR_EXPORT_COMPLIANCE,REJECTED," \
                             "WAITING_FOR_REVIEW,IN_REVIEW,READY_FOR_REVIEW,ACCEPTED," \
                             "PENDING_DEVELOPER_RELEASE,PENDING_APPLE_RELEASE," \
                             "PROCESSING_FOR_APP_STORE,READY_FOR_SALE"

  def versions_path
    "/v1/apps/app-1/appStoreVersions?filter[appStoreState]=#{RELEVANT_VERSION_STATES}&limit=200"
  end

  def version_localizations_path(version_id, locale = "en-US")
    "/v1/appStoreVersions/#{version_id}/appStoreVersionLocalizations?filter[locale]=#{locale}"
  end

  def transport(overrides = {})
    fixtures = {
      "/v1/apps/app-1/appInfos" => File.join(FIXTURES_DIR, "app_infos.json"),
      "/v1/appInfos/info-pending/appInfoLocalizations?filter[locale]=en-US" => File.join(FIXTURES_DIR, "app_info_localizations.json"),
      versions_path => File.join(FIXTURES_DIR, "app_store_versions.json"),
      version_localizations_path("version-pending") => File.join(FIXTURES_DIR, "app_store_version_localizations.json"),
      version_localizations_path("version-live") => File.join(FIXTURES_DIR, "app_store_version_localizations.json")
    }.merge(overrides)
    FakeTransport.new(fixtures)
  end

  # G/stray-fixture fix: write dynamic fixtures under Dir.mktmpdir instead of
  # into the tracked spec/fixtures/ directory, so running the suite never
  # leaves an untracked file behind (see store_test.rb for the same pattern).
  def write_json_fixture(data)
    dir = Dir.mktmpdir("client_test_fixture")
    path = File.join(dir, "fixture.json")
    File.write(path, JSON.generate(data))
    path
  end

  def live_only_versions_fixture
    write_json_fixture({ "data" => [{ "id" => "version-live", "attributes" => { "appStoreState" => "READY_FOR_SALE" } }] })
  end

  def waiting_for_review_only_versions_fixture
    write_json_fixture({ "data" => [{ "id" => "version-review", "attributes" => { "appStoreState" => "WAITING_FOR_REVIEW" } }] })
  end

  def live_only_app_infos_fixture
    write_json_fixture({ "data" => [{ "id" => "info-live", "attributes" => { "appStoreState" => "READY_FOR_SALE" } }] })
  end

  def empty_localizations_fixture
    write_json_fixture({ "data" => [] })
  end

  def client(t = transport, locale: "en-US")
    MetadataSync::Client.new(transport: t, app_id: "app-1", locale: locale)
  end

  def test_fetch_app_info_picks_non_live_app_info
    result = client.fetch_app_info
    assert_equal({ "name" => "ListNudge", "subtitle" => "One list. Everyone's on it." }, result)
  end

  def test_fetch_version_info_prefers_editable_version
    result = client.fetch_version_info
    assert_equal "ListNudge is the grocery list that remembers for you.", result["description"]
    assert_equal "grocery,shopping list", result["keywords"]
  end

  # Confirmed against a real app (NozzleCast) in WAITING_FOR_REVIEW: Apple's
  # own App Store Connect UI says you can edit *some* information in this
  # state, so it must not be treated as fully locked like READY_FOR_SALE --
  # fetch/pull must still be able to see this version's data.
  def test_fetch_version_info_falls_back_to_waiting_for_review_version
    t = transport(
      versions_path => waiting_for_review_only_versions_fixture,
      version_localizations_path("version-review") => File.join(FIXTURES_DIR, "app_store_version_localizations.json")
    )
    result = client(t).fetch_version_info
    assert_equal "ListNudge is the grocery list that remembers for you.", result["description"]
  end

  # But we don't yet know which fields Apple actually lets through a PATCH in
  # WAITING_FOR_REVIEW -- until that's tested for real, push must stay
  # conservative and still require a genuinely editable version.
  def test_push_version_info_still_raises_when_only_waiting_for_review_version_exists
    t = transport(versions_path => waiting_for_review_only_versions_fixture)
    error = assert_raises(MetadataSync::Client::NoEditableVersionError) do
      client(t).push_version_info({ "description" => "New description" })
    end
    assert_match(/No editable App Store version/, error.message)
    assert_empty t.patches
  end

  # REJECTED (distinct from DEVELOPER_REJECTED/METADATA_REJECTED) reasoned
  # into EDITABLE_VERSION_STATES: any rejected version must be editable to
  # let the developer fix and resubmit. Not individually confirmed against a
  # real app, but the alternative (treating a rejected version as locked)
  # would be clearly wrong.
  def test_push_version_info_treats_rejected_as_editable
    rejected_fixture = write_json_fixture(
      { "data" => [{ "id" => "version-rejected", "attributes" => { "appStoreState" => "REJECTED" } }] }
    )
    t = transport(
      versions_path => rejected_fixture,
      version_localizations_path("version-rejected") => File.join(FIXTURES_DIR, "app_store_version_localizations.json")
    )
    client(t).push_version_info({ "description" => "New description" })
    assert_equal "/v1/appStoreVersionLocalizations/loc-version-en", t.patches.first[:path]
  end

  # The foundational safety fix: an app whose only version sits in a state we
  # don't recognize at all (not editable, not readable-only, not live) must
  # fail loudly rather than silently returning {} -- which metadata_pull
  # would otherwise write straight through, wiping any already-seeded
  # metadata_config/*.yml with nothing.
  def test_fetch_version_info_raises_when_no_version_resolves_at_all
    unrecognized_fixture = write_json_fixture(
      { "data" => [{ "id" => "version-limbo", "attributes" => { "appStoreState" => "PENDING_CONTRACT" } }] }
    )
    t = transport(versions_path => unrecognized_fixture)
    error = assert_raises(MetadataSync::Client::NoVersionFoundError) do
      client(t).fetch_version_info
    end
    assert_match(/No App Store version found/, error.message)
  end

  def test_fetch_version_info_raises_when_no_localization_for_locale
    t = transport(version_localizations_path("version-pending") => empty_localizations_fixture)
    error = assert_raises(MetadataSync::Client::NoVersionFoundError) do
      client(t).fetch_version_info
    end
    assert_match(/no appStoreVersionLocalization/, error.message)
  end

  def test_push_app_info_patches_only_the_pending_localization
    t = transport
    client(t).push_app_info({ "subtitle" => "New subtitle" })
    assert_equal 1, t.patches.size
    assert_equal "/v1/appInfoLocalizations/loc-info-en", t.patches.first[:path]
    assert_equal({ "subtitle" => "New subtitle" }, t.patches.first[:body]["data"]["attributes"])
  end

  # Same class of bug as the promotionalText fix, on the appInfo side: a read
  # doesn't need an editable appInfo (metadata_pull should still work against
  # a shipped app with no open version), so fetch_app_info must still fall
  # back to the live appInfo rather than raising.
  def test_fetch_app_info_falls_back_to_live_app_info_when_none_editable
    t = transport(
      "/v1/apps/app-1/appInfos" => live_only_app_infos_fixture,
      "/v1/appInfos/info-live/appInfoLocalizations?filter[locale]=en-US" => File.join(FIXTURES_DIR, "app_info_localizations.json")
    )
    result = client(t).fetch_app_info
    assert_equal({ "name" => "ListNudge", "subtitle" => "One list. Everyone's on it." }, result)
  end

  # A write does need an editable appInfo: an app with no non-live appInfo
  # has nothing name/subtitle can be PATCHed onto. Confirmed against a real
  # ListNudge app that's fully READY_FOR_SALE -- Apple rejects the analogous
  # version-level PATCH in that state, so raise the same clear, actionable
  # error here rather than attempting a doomed PATCH.
  def test_push_app_info_raises_when_no_editable_app_info
    t = transport("/v1/apps/app-1/appInfos" => live_only_app_infos_fixture)
    error = assert_raises(MetadataSync::Client::NoEditableVersionError) do
      client(t).push_app_info({ "subtitle" => "New subtitle" })
    end
    assert_match(/No editable App Info found/, error.message)
    assert_empty t.patches
  end

  def test_push_version_info_camelizes_keys
    t = transport
    client(t).push_version_info({ "marketing_url" => "https://listnudge.app" })
    body = t.patches.first[:body]
    assert_equal({ "marketingUrl" => "https://listnudge.app" }, body["data"]["attributes"])
  end

  def test_push_version_info_raises_when_no_editable_version_and_field_requires_one
    t = transport(versions_path => live_only_versions_fixture)
    error = assert_raises(MetadataSync::Client::NoEditableVersionError) do
      client(t).push_version_info({ "description" => "New description" })
    end
    assert_match(/No editable App Store version/, error.message)
  end

  # Confirmed against a real ListNudge app in READY_FOR_SALE: nothing on a
  # live version is editable via the API, promotionalText included -- the
  # original plan's assumption that Apple lets you edit promotional text on
  # the live version without a new one is wrong. promotionalText gets no
  # special treatment: it requires an editable version exactly like every
  # other version_info field.
  def test_push_version_info_raises_for_promotional_text_with_no_editable_version
    t = transport(versions_path => live_only_versions_fixture)
    error = assert_raises(MetadataSync::Client::NoEditableVersionError) do
      client(t).push_version_info({ "promotional_text" => "New promo" })
    end
    assert_match(/No editable App Store version/, error.message)
  end

  def test_push_version_info_targets_editable_version_for_promotional_text_when_one_exists
    t = transport
    version, _loc = client(t).resolve_version_target!({ "promotional_text" => "New promo" })
    assert_equal "version-pending", version["id"], "promotional_text must resolve to the editable version, not fall through to the live one"

    client(t).push_version_info({ "promotional_text" => "New promo" })
    assert_equal "/v1/appStoreVersionLocalizations/loc-version-en", t.patches.first[:path]
  end

  # I1: metadata_push must not apply a partial push. If version_info's target
  # can't be resolved (no editable version for a field that requires one),
  # resolve_version_target! must raise BEFORE any PATCH is issued -- so a
  # caller that resolves version_info's target first (as the metadata_push
  # lane now does) never sends app_info's PATCH when version_info would fail.
  def test_resolve_version_target_raises_before_any_patch_is_sent
    t = transport(versions_path => live_only_versions_fixture)
    c = client(t)

    assert_raises(MetadataSync::Client::NoEditableVersionError) do
      c.resolve_version_target!({ "description" => "New description" })
    end

    # Simulate the lane's ordering: app_info is only pushed after
    # resolve_version_target! succeeds. Since it raised, no PATCH of any kind
    # -- app_info or version_info -- should have been sent.
    assert_empty t.patches, "no PATCH should be sent when version_info's target can't be resolved"
  end

  def test_resolve_version_target_returns_version_and_localization_on_success
    version, loc = client.resolve_version_target!({ "marketing_url" => "https://listnudge.app" })
    assert_equal "version-pending", version["id"]
    assert_equal "loc-version-en", loc["id"]
  end

  # M1: version_localization can return nil (e.g. no localization for the
  # configured locale on the resolved version). Client#push_version_info used
  # to call `loc['id']` on that nil directly -- a bare NoMethodError. It must
  # instead raise a clear, explicit error, matching the pattern
  # app_info_localization already uses for the analogous missing-locale case.
  def test_resolve_version_target_raises_clear_error_when_localization_missing
    t = transport(version_localizations_path("version-pending", "de-DE") => empty_localizations_fixture)
    c = client(t, locale: "de-DE")

    error = assert_raises(RuntimeError) do
      c.resolve_version_target!({ "marketing_url" => "https://listnudge.app" })
    end
    assert_match(/No appStoreVersionLocalization for locale de-DE/, error.message)
  end
end
