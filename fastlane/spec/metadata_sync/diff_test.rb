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

  # M3 regression coverage for what caused C3 (the seeded version_info.yml
  # producing a false diff on its first real run against live values).

  # nil (repo field genuinely unset) must NOT be treated as equal-and-skippable
  # to an empty string live value -- changed_fields already skips nil repo
  # values unconditionally, so the field must simply never appear in the diff,
  # regardless of what live holds (including "", which IS different from nil).
  def test_nil_repo_value_is_always_skipped_even_when_live_is_empty_string
    repo = { "marketing_url" => nil }
    live = { "marketing_url" => "" }
    diff = MetadataSync::Diff.changed_fields(repo, live, %w[marketing_url])
    assert_empty diff
  end

  # A trailing-newline/whitespace difference (e.g. a `|` block scalar vs a
  # live value with no trailing newline) IS a real, meaningful diff and must
  # be surfaced, not silently treated as equal.
  def test_trailing_newline_difference_is_treated_as_a_real_diff
    repo = { "description" => "Same copy.\n" }
    live = { "description" => "Same copy." }
    diff = MetadataSync::Diff.changed_fields(repo, live, %w[description])
    assert_equal({ "description" => "Same copy.\n" }, diff)
  end
end
