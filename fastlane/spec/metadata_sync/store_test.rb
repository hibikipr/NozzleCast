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

  # M2: Store.load used to raise a bare Errno::ENOENT for an unseeded locale
  # (e.g. ASC_LOCALE=de-DE bundle exec fastlane metadata_push with no prior
  # metadata_pull for that locale) -- reachable today, not just latent. It
  # must instead raise a clear error naming the missing directory and
  # suggesting metadata_pull.
  def test_load_raises_clear_error_for_unseeded_locale
    Dir.mktmpdir do |dir|
      missing_locale_dir = File.join(dir, "de-DE")

      error = assert_raises(RuntimeError) do
        MetadataSync::Store.load(missing_locale_dir)
      end
      assert_match(/No seeded metadata found in #{Regexp.escape(missing_locale_dir)}/, error.message)
      assert_match(/metadata_pull/, error.message)
    end
  end
end
