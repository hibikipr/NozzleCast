`background`/`fonts/*` in Framefile.json are functional placeholders (plain white background, Liberation Sans). Swap for real branded assets before shipping updated screenshots to the App Store.

# Framefile.json

This config drives `frameit` (invoked via the `ios frame_app_screenshots` fastlane lane) to overlay device frames and marketing headline/keyword text onto raw screenshots.

- `background`: currently `backgrounds/white.png`, a plain white placeholder. Replace with an actual branded background before shipping.
- `fonts/*`: currently bundled Liberation Sans (an Arial/Helvetica-metric-compatible, OFL-licensed substitute), not true Helvetica. Replace with a properly licensed font if a different look is required.

iPhone 6.9" (1320x2868) is registered natively by frameit as of fastlane
2.239.0+; the local `frameit_device_patch.rb` that used to backfill it was
removed when this repo moved off the Ruby 2.6 / fastlane 2.230.0 pin.
