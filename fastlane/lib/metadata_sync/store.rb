require "yaml"
require "fileutils"

module MetadataSync
  class Store
    APP_INFO_FIELDS = %w[name subtitle].freeze
    VERSION_INFO_FIELDS = %w[description keywords promotional_text marketing_url support_url whats_new].freeze

    def self.load(locale_dir)
      {
        app_info: YAML.load_file(File.join(locale_dir, "app_info.yml")) || {},
        version_info: YAML.load_file(File.join(locale_dir, "version_info.yml")) || {}
      }
    end

    def self.save(locale_dir, data)
      FileUtils.mkdir_p(locale_dir)
      File.write(File.join(locale_dir, "app_info.yml"), data[:app_info].to_yaml)
      File.write(File.join(locale_dir, "version_info.yml"), data[:version_info].to_yaml)
    end
  end
end
