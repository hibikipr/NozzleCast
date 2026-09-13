require "frameit"

# The pinned fastlane/frameit version (see fastlane/Gemfile.lock) predates
# Apple's "iPhone 6.9-inch" display class (iPhone 16 Pro Max / iPhone 17 Pro
# Max, 1320x2868 px). frameit's device whitelist (frameit/lib/frameit/device_types.rb)
# tops out at the iPhone 14 Pro Max, so `frame_screenshots` fails with
# "Unsupported screen size [1320, 2868]" even though the downloaded frame
# templates (`fastlane frameit download_frames`) already ship the matching
# "Apple iPhone 16 Pro Max"/"Apple iPhone 17 Pro Max" artwork and offsets.
#
# Register the missing device so our iPhone-6.9 screenshots can be framed
# without bumping fastlane (bumping is blocked: newer fastlane requires
# Ruby >= 3.1, and this project vendors Ruby 2.6.0).
module Frameit
  module Devices
    IPHONE_69 ||= Device.new(
      "iphone-6-9",
      "Apple iPhone 16 Pro Max",
      # priority: 13 — one above the current highest priority in frameit's own
      # device_types.rb (IPHONE_14_PRO_MAX at 12). frameit uses this value only
      # to order devices when disambiguating screen-size matches, so this is a
      # deliberate manual coupling to frameit's internal numbering (not an
      # arbitrary constant) and must be revisited if a future frameit upgrade
      # adds its own higher-priority devices.
      13,
      [[1320, 2868], [2868, 1320]],
      460,
      "Black Titanium",
      Platform::IOS
    )
  end
end
