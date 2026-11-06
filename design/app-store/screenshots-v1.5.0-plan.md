# v1.5.0 App Store screenshots: plan

Status: fastlane bumped and screenshot data ready. Nothing has been captured yet.

## Toolchain

- `fastlane/Gemfile.lock` pins fastlane **2.241.1**. The latest is **2.241.2** (2026-10-26).
- 2.241.2 fixes three security advisories:
  - spaceship: GHSA-m67f-ghvw-j7qp
  - match: GHSA-hqmj-jmgc-wmwp
  - Fastlane.Swift: GHSA-gqqf-9mh3-3578
- The spaceship fix matters here: `deliver` uploads through spaceship.
- 2.241.2 doesn't change frameit or deliver's screenshot sizes:
  - iPad 13" still can't be framed.
  - iPhone Duo still passes through unframed, as one `APP_IPHONE_DUO` set with 10 per locale.
- Bump with `bundle update fastlane` in `fastlane/`. The other four fastlane apps also pin 2.241.1.

## Why reshoot

The current iPhone 6.9" and 6.5" set dates from 2026-10-03 (v1.2.0). None of the 1.5.0 features appear in it:
- animated printers
- card layouts
- the redesigned printer screen
- the redesigned Live Activity
- SpoolBuddy
- Prints history with pictures and verdicts
- the Notifications list

Its accent colour is also out of date.

## Shot list

Apple rejected 1.0 under 5.2.1 for naming Bambuddy, so no headline or metadata names Bambuddy or SpoolBuddy (part of the same project). The app's own UI still says SpoolBuddy on shot 05.

This covers iPhone 6.9" and 6.5". iPad 13" uses the same file names.

| # | File | Screen and state | Keyword / title (Framefile) |
|---|------|------------------|-----------------------------|
| 01 | `01-monitor-animated` | Monitor, **Hero** layout. One printer printing (animated, camera), one paused (cover), one idle (last-print thumbnail). | ALIVE ON SCREEN / Watch every printer at work |
| 02 | `02-card-layouts` | Monitor in **Twin tiles**, with the layout picker open. | YOUR LAYOUT / Four ways to see your farm |
| 03 | `03-printer-detail` | Redesigned printer screen while printing: job card, temperature chips, AMS columns. | FULL CONTROL / Every detail of every print |
| 04 | `04-live-activity` | Lock Screen showing the redesigned Live Activity, with a sharp cover on its contrast tile. | ALWAYS IN VIEW / Track prints from your Lock Screen |
| 05 | `05-spoolbuddy-scan` | Scan › SpoolBuddy after reading an unknown Bambu tag, with the **New Spool** form prefilled from the tag. | SPOOL READER / Drop a spool, it's in your inventory |
| 06 | `06-prints-history` | Prints › History: thumbnails, Good and Reject badges, one Needs Verdict row. | PRINT HISTORY / Every print, and how it came out |
| 07 | `07-print-queue` | Prints › Queue, showing the **Print anyway?** dialog for a held job. | SMART QUEUE / Never print on the wrong filament |
| 08 | `08-notifications` | Notifications list with camera photos, and one row swiped to **Mute**. | ALERTS THAT MATTER / Photos, and mute the noise |
| 09 | `09-inventory` | Inventory with the Low Stock filter, showing spools in the AMS and in storage. | FILAMENT INVENTORY / Know every spool you own |
| 10 | `10-widget-large` | Home Screen with the large AMS widget. | ON YOUR HOME SCREEN / Filament status without opening the app |

That's 10 shots, the limit per set.

These replace the old shots:
- `01-monitor-live-status` becomes 01.
- `02-printer-detail` becomes 03.
- `03-ams-filament` is split between 03 and 09.
- `04-widget-large` becomes 10.
- `05-live-activity` becomes 04.

**iPhone Duo** gets one set of 10 for all poses:
- open: 01, 03, 06, 08
- partially open: 03 (camera pinned on top), 05
- closed: 01, 04, 07, 09

There's no open-portrait shot, because the 10-shot limit is tight.

## Data

Screenshot mode (Debug builds launched with `-NCScreenshotMode`, no server configured) now has
everything the shot list needs. `NozzleCast/ScreenshotMocks.swift` serves it; the images are
Blender renders in `NozzleCast/ScreenshotMocks/`, left out of Release builds.
Re-render them with `design/app-store/screenshot-mocks/render.py` (usage in its header). After
rendering, each cover was cropped to the model, padded to about 1.45× its larger side and resized
to 512 px.

- **Printers:** Studio H2C printing (64%), Workshop X1C printing (22%), Office P1S paused (31%),
  Garage A1 idle. Printing cards show mock chamber camera frames. Paused and idle cards show the
  job's or last print's cover, fitted to the tile.
- **Live Activities** start for both printing printers, with their covers. Lock the simulator to
  see them.
- **Prints:** the queue and history show thumbnails. **Start** on the staged Headphone Stand
  shows **Print anyway?** (not enough PLA).
- **Scan › SpoolBuddy:** an online SpoolBuddy with an unknown Bambu tag (PLA Matte, Mandarin
  Orange) and 1,246 g on the scale. **New Spool** opens prefilled.
- **Notifications:** five alerts, four with camera photos, including "MQTT Command verification
  failed" for the Mute swipe.

Capture notes:
- The launch right after `simctl install` loses the argument: terminate and launch again with
  `xcrun simctl launch <udid> com.victormanuel.NozzleCast -NCScreenshotMode`.
- Use a simulator without your server configured, or demo data never shows.
- Add `--operatorName ""` to the status bar override; the Lock Screen otherwise says "Carrier".

## Steps

1. Done: fastlane 2.241.2.
2. Done: screenshot-mode data (see Data).
3. Capture the shots:
   1. Boot these simulators:
      - iPhone 17 Pro Max (6.9")
      - a 6.5" iPhone
      - iPad Pro 13"
      - iPhone Duo
   2. Set the status bar on each with `xcrun simctl status_bar <udid> override --time 9:41 --batteryState charged --batteryLevel 100`.
   3. Launch the app with `-NCScreenshotMode`.
   4. For each shot, run `fastlane/scripts/capture_screenshots.sh <udid> <class> en-US <NN-name>`.
   5. Remove the old files.
4. Update the `data` array in `fastlane/Framefile.json` to match the table. Then run `bundle exec fastlane ios frame_app_screenshots` and check `screenshots_framed/en-US/`.
5. Write the 1.5.0 `whats_new` in `metadata_config/en-US/version_info.yml`. It still has the previous release's text.
6. Once version 1.5.0 exists in App Store Connect, upload with `deliver`. This needs the user's OK first.
