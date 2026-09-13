require "minitest/autorun"
require "tmpdir"
require "metadata_sync/store"

class StoreTest < Minitest::Test
  def test_round_trips_app_info_and_version_info
    Dir.mktmpdir do |dir|
      data = {
        app_info: { "name" => "ListNudge", "subtitle" => "One list. Everyone's on it." },
        version_info: { "description" => "desc", "keywords" => "a,b", "promotional_text" => "promo",
                         "marketing_url" => "", "support_url" => "", "whats_new" => "" }
      }
      MetadataSync::Store.save(dir, data)
      loaded = MetadataSync::Store.load(dir)
      assert_equal data[:app_info], loaded[:app_info]
      assert_equal data[:version_info], loaded[:version_info]
    end
  end
end
