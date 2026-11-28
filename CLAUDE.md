# NozzleCast

iOS 26 companion app for a self-hosted Bambuddy server. This repo is public.
Read [ARCHITECTURE.md](ARCHITECTURE.md) and [CONTRIBUTING.md](CONTRIBUTING.md) first; they explain the design
decisions and the deliberate non-features. Update ARCHITECTURE.md in the same change when you alter one.

## Project

- Targets: `NozzleCast`, `NozzleCastWidgets`, `NozzleCastNSE`, `NozzleCastTests`. Shared logic lives in the
  `NozzleCastShared` Swift package.
- `NozzleCast.xcodeproj` is edited directly in Xcode; there is no project generator.
- State lives in one `@Observable` `AppStore`; views read it through the environment. Don't add a
  reducer or action layer.

## Tests

- `cd NozzleCastShared && swift test` (what CI runs). Add tests in `NozzleCastShared/Tests/` for behavior
  changes in shared logic.
- fastlane tooling has its own tests: `cd fastlane && bundle install && bundle exec rake`.

## Rules

- Credentials (server URL, API key, relay and ntfy settings) live only in the Keychain, using the shared
  access group the app and the NSE both read. Never `UserDefaults` or plain files. Never commit real
  credentials, hostnames, `.p8` keys or Firebase config files.
- The Live Activity (Lock Screen and Dynamic Island) shows the job's `coverImage` from the content state,
  never the live camera snapshot (`liveSnapshot` / `preferredThumbnail`), and has no LIVE badge.
- Jobs the printer downloads from an https:// link (MakerWorld, Handy, Studio) are "HTTPS-dispatched prints"
  in code, comments, logs, PRs, release notes and UI text. Never call them "cloud prints".
- Don't change `fastlane/metadata_config/`: it is the App Store listing, and merges to `main` push it to
  App Store Connect.

## App Store tooling

- fastlane lanes: `metadata_pull`, `metadata_push`, `frame_app_screenshots`, `upload_screenshots`.
- iPhone Duo screenshots upload as one `APP_IPHONE_DUO` set (fastlane 2.241.1+), so closed and open poses
  share the 10-per-locale limit. Duo captures in `design/app-store/` aren't uploaded until copied into
  `fastlane/screenshots/`.
- Update the fastlane lockfile with `bundle lock --update fastlane` inside `fastlane/`.

## Pull requests

- Branch from `main`; direct pushes to `main` are blocked. Say how a change was tested.
