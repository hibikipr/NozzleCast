`background`/`fonts/*` in Framefile.json are functional placeholders (plain white background, Liberation Sans). Swap for real branded assets before shipping updated screenshots to the App Store.

# Framefile.json

This config drives `frameit` (invoked via the `ios frame_app_screenshots` fastlane lane) to overlay device frames and marketing headline/keyword text onto raw screenshots.

- `background`: currently `backgrounds/white.png`, a plain white placeholder. Replace with an actual branded background before shipping.
- `fonts/*`: currently bundled Liberation Sans (an Arial/Helvetica-metric-compatible, OFL-licensed substitute), not true Helvetica. Replace with a properly licensed font if a different look is required.

See `fastlane/lib/frameit_device_patch.rb` for the related device-registration patch needed to frame iPhone 6.9" screenshots on the pinned fastlane/frameit version.
