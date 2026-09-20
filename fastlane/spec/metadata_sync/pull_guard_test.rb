require "minitest/autorun"
require "metadata_sync/pull_guard"

class PullGuardTest < Minitest::Test
  def existing(version_info = {}, app_info = {})
    { app_info: app_info, version_info: version_info }
  end

  def test_flags_a_field_that_would_be_blanked
    have = existing({ "promotional_text" => "Blast off with Kai!", "description" => "d" })
    want = existing({ "promotional_text" => nil, "description" => "d" })

    blankings = MetadataSync::PullGuard.blankings(have, want)

    assert_equal 1, blankings.length
    assert_equal :version_info, blankings.first.section
    assert_equal "promotional_text", blankings.first.field
  end

  def test_flags_empty_string_and_whitespace_as_blanking
    have = existing({ "whats_new" => "real notes" })

    assert_equal 1, MetadataSync::PullGuard.blankings(have, existing({ "whats_new" => "" })).length
    assert_equal 1, MetadataSync::PullGuard.blankings(have, existing({ "whats_new" => "   \n" })).length
  end

  def test_does_not_flag_a_real_content_change
    have = existing({ "description" => "old copy" })
    want = existing({ "description" => "new copy from ASC" })

    assert_empty MetadataSync::PullGuard.blankings(have, want)
  end

  def test_does_not_flag_filling_an_empty_repo_field
    have = existing({ "whats_new" => nil })
    want = existing({ "whats_new" => "notes from ASC" })

    assert_empty MetadataSync::PullGuard.blankings(have, want)
  end

  def test_does_not_flag_when_both_sides_are_empty
    assert_empty MetadataSync::PullGuard.blankings(existing({ "whats_new" => nil }), existing({ "whats_new" => "" }))
  end

  def test_covers_app_info_fields_too
    have = existing({}, { "subtitle" => "Learn to read" })
    want = existing({}, { "subtitle" => nil })

    blankings = MetadataSync::PullGuard.blankings(have, want)

    assert_equal 1, blankings.length
    assert_equal :app_info, blankings.first.section
    assert_equal "subtitle", blankings.first.field
  end

  def test_reproduces_the_kaireads_1_3_0_draft_case
    live_1_2_0 = existing({
      "description" => "Kai Reads turns learning to read into a real adventure.",
      "keywords" => "phonics,sight words",
      "promotional_text" => "Blast off with Kai!",
      "whats_new" => "Story Planet now offers a whole shelf of stories."
    })
    draft_1_3_0 = existing({
      "description" => "Kai Reads turns learning to read into a real adventure.",
      "keywords" => "phonics,sight words",
      "promotional_text" => nil,
      "whats_new" => nil
    })

    fields = MetadataSync::PullGuard.blankings(live_1_2_0, draft_1_3_0).map(&:field).sort

    assert_equal %w[promotional_text whats_new], fields
  end

  def test_describe_truncates_long_previews
    have = existing({ "description" => "x" * 200 })
    text = MetadataSync::PullGuard.describe(MetadataSync::PullGuard.blankings(have, existing({ "description" => nil })))

    assert_includes text, "version_info.description"
    assert_includes text, "200 chars"
    assert_includes text, "…"
  end
end
