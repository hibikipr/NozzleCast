require "metadata_sync/store"

module MetadataSync
  # Guards `metadata_pull` against silently replacing real repo content with
  # empty values from App Store Connect.
  #
  # Why this exists: `fetch_version_info` resolves the *editable* version
  # first, falling back to review-pipeline and then live. That is correct for
  # pushing, but it means a pull does not necessarily read the version that is
  # actually on the App Store. When a new version is started in App Store
  # Connect, Apple carries `description`/`keywords`/`marketingUrl`/`supportUrl`
  # forward from the previous version but leaves `promotionalText` and
  # `whatsNew` empty on the new draft. A pull at that moment reads the draft
  # and writes those two fields back as blank, wiping copy the repo correctly
  # held for the live version.
  #
  # Observed for real on KaiReads 2026-09-19: a 1.3.0 draft in
  # PREPARE_FOR_SUBMISSION had both fields empty while live 1.2.0 had 152 and
  # 550 characters respectively, and the pull blanked both in the repo.
  # `metadata_config/` being committed is what made that recoverable -- this
  # guard is so it does not depend on that.
  class PullGuard
    Blanking = Struct.new(:section, :field, :existing, keyword_init: true)

    SECTIONS = {
      app_info: Store::APP_INFO_FIELDS,
      version_info: Store::VERSION_INFO_FIELDS
    }.freeze

    # Fields that currently hold a non-empty value in the repo and would be
    # replaced by an empty/nil value from App Store Connect.
    def self.blankings(existing, incoming)
      SECTIONS.flat_map do |section, fields|
        have = existing[section] || {}
        want = incoming[section] || {}
        fields.filter_map do |field|
          next unless present?(have[field])
          next if present?(want[field])

          Blanking.new(section: section, field: field, existing: have[field])
        end
      end
    end

    def self.present?(value)
      !value.nil? && !value.to_s.strip.empty?
    end

    def self.describe(blankings)
      blankings.map do |b|
        preview = b.existing.to_s.gsub(/\s+/, " ").strip
        preview = "#{preview[0, 60]}…" if preview.length > 60
        "  #{b.section}.#{b.field} (currently #{b.existing.to_s.length} chars: \"#{preview}\")"
      end.join("\n")
    end
  end
end
