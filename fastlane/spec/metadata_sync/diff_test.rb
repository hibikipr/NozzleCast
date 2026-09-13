require "minitest/autorun"
require "metadata_sync/store"
require "metadata_sync/diff"

class DiffTest < Minitest::Test
  def test_only_changed_fields_are_returned
    repo = {
      app_info: { "name" => "ListNudge", "subtitle" => "New subtitle" },
      version_info: { "description" => "same", "keywords" => "new,keywords", "promotional_text" => "same",
                       "marketing_url" => "", "support_url" => "", "whats_new" => "" }
    }
    live = {
      app_info: { "name" => "ListNudge", "subtitle" => "Old subtitle (trimmed by review)" },
      version_info: { "description" => "same", "keywords" => "old,keywords", "promotional_text" => "same",
                       "marketing_url" => "", "support_url" => "", "whats_new" => "" }
    }

    diff = MetadataSync::Diff.compute(repo, live)

    assert_equal({ "subtitle" => "New subtitle" }, diff[:app_info])
    assert_equal({ "keywords" => "new,keywords" }, diff[:version_info])
  end

  def test_no_changes_yields_empty_hashes
    same = { app_info: { "name" => "X", "subtitle" => "Y" }, version_info: { "description" => "Z" } }
    diff = MetadataSync::Diff.compute(same, same)
    assert_empty diff[:app_info]
    assert_empty diff[:version_info]
  end
end
