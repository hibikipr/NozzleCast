require "metadata_sync/store"

module MetadataSync
  class Diff
    def self.compute(repo, live)
      {
        app_info: changed_fields(repo[:app_info], live[:app_info], Store::APP_INFO_FIELDS),
        version_info: changed_fields(repo[:version_info], live[:version_info], Store::VERSION_INFO_FIELDS)
      }
    end

    def self.changed_fields(repo_hash, live_hash, fields)
      fields.each_with_object({}) do |field, changes|
        repo_value = repo_hash[field]
        live_value = live_hash[field]
        changes[field] = repo_value if repo_value != live_value && !repo_value.nil?
      end
    end
  end
end
