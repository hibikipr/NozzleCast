require "minitest/autorun"
require "json"
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

  def transport(overrides = {})
    fixtures = {
      "/v1/apps/app-1/appInfos" => File.join(FIXTURES_DIR, "app_infos.json"),
      "/v1/appInfos/info-pending/appInfoLocalizations" => File.join(FIXTURES_DIR, "app_info_localizations.json"),
      "/v1/apps/app-1/appStoreVersions" => File.join(FIXTURES_DIR, "app_store_versions.json"),
      "/v1/appStoreVersions/version-pending/appStoreVersionLocalizations" => File.join(FIXTURES_DIR, "app_store_version_localizations.json"),
      "/v1/appStoreVersions/version-live/appStoreVersionLocalizations" => File.join(FIXTURES_DIR, "app_store_version_localizations.json")
    }.merge(overrides)
    FakeTransport.new(fixtures)
  end

  def client(t = transport)
    MetadataSync::Client.new(transport: t, app_id: "app-1", locale: "en-US")
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

  def test_push_app_info_patches_only_the_pending_localization
    t = transport
    client(t).push_app_info({ "subtitle" => "New subtitle" })
    assert_equal 1, t.patches.size
    assert_equal "/v1/appInfoLocalizations/loc-info-en", t.patches.first[:path]
    assert_equal({ "subtitle" => "New subtitle" }, t.patches.first[:body]["data"]["attributes"])
  end

  def test_push_version_info_camelizes_keys
    t = transport
    client(t).push_version_info({ "marketing_url" => "https://listnudge.app" })
    body = t.patches.first[:body]
    assert_equal({ "marketingUrl" => "https://listnudge.app" }, body["data"]["attributes"])
  end

  def live_only_versions_fixture
    path = File.join(FIXTURES_DIR, "app_store_versions_live_only.json")
    File.write(
      path,
      JSON.generate({ "data" => [{ "id" => "version-live", "attributes" => { "appStoreState" => "READY_FOR_SALE" } }] })
    )
    path
  end

  def test_push_version_info_raises_when_no_editable_version_and_field_requires_one
    t = transport("/v1/apps/app-1/appStoreVersions" => live_only_versions_fixture)
    error = assert_raises(MetadataSync::Client::NoEditableVersionError) do
      client(t).push_version_info({ "description" => "New description" })
    end
    assert_match(/No editable App Store version/, error.message)
  end

  def test_push_version_info_allows_promotional_text_on_live_version
    t = transport("/v1/apps/app-1/appStoreVersions" => live_only_versions_fixture)
    client(t).push_version_info({ "promotional_text" => "New promo" })
    assert_equal "/v1/appStoreVersionLocalizations/loc-version-en", t.patches.first[:path]
  end
end
