# fastlane/README.md (App Store Connect automation)

## Metadata sync

- Source of truth: `fastlane/metadata_config/<locale>/{app_info,version_info}.yml`.
- `bundle exec fastlane metadata_pull` — pull live values into the repo (use after App Review edits something, to reconcile).
- `bundle exec fastlane metadata_push dry_run:true` — see what would change without writing anything.
- `bundle exec fastlane metadata_push` — PATCH only the fields that differ. Never overwrites fields you haven't touched.
- Requires env vars: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`, `ASC_APP_ID`, optional `ASC_LOCALE` (default `en-US`).

## Screenshots

- Capture: boot a simulator, manually navigate to the target screen, then run
  `fastlane/scripts/capture_screenshots.sh <udid> <device-class> <locale> <NN-shot-name>`.
- Frame: `bundle exec fastlane ios frame_app_screenshots` runs a three-stage
  pipeline per locale, not a simple copy-and-frame-in-place:
  1. **Stage** — every `fastlane/screenshots/<locale>/<device-class>/*.png`
     bare screenshot is flattened into a scratch
     `fastlane/screenshots_staging/<locale>/` folder (gitignored, wiped and
     recreated each run), with each filename prefixed by its device class,
     e.g. `iPhone-6.9-01-lists-home.png`, purely to keep names unique across
     device classes that reuse the same shot number.
  2. **Frame** — the correct `Framefile.json` (the locale's own
     `fastlane/screenshots/<locale>/Framefile.json` if present, else the
     shared `fastlane/Framefile.json`) is copied directly into that same
     staging folder, and `frameit` is run there. Placing the config file
     right next to the screenshots it applies to is required: frameit's
     `create_config` (frameit's `runner.rb`) only checks for `Framefile.json`
     exactly 1, 2, or 4 directory levels above the screenshot file — never 3
     — so a config living further away (e.g. the previous layout, where
     `fastlane/Framefile.json` sat 3 levels above a file in
     `screenshots_framed/<locale>/`) is silently never found, and frameit
     falls back to a frame-only "easy mode" with no headline text and,
     critically, no resize to the exact App Store Connect device resolution.
     This staging-folder placement is the same mechanism as the "Per-locale
     copy override" below, just used unconditionally for every locale.
  3. **Publish** — only the resulting `*_framed.png` files (never the bare
     originals) are copied into `fastlane/screenshots_framed/<locale>/`,
     which is cleaned and recreated each run and stays **flat** (no
     device-class subfolders). This is required for `deliver` to find them
     (its screenshot loader only globs one level deep under the locale
     folder and identifies device class from each image's pixel dimensions,
     never from folder or file names), and — because nothing but
     genuinely-framed output ever lands there — it also means deliver's
     loader (which partitions bare-vs-framed screenshots by checking whether
     `"framed"` appears anywhere in the path, and would otherwise match
     every file under a directory literally named `screenshots_framed`) has
     nothing ambiguous left to double-count.
  (Always use the `ios` prefix and the full lane name — the lane was
  deliberately named `frame_app_screenshots`, not `frame_screenshots`,
  because the latter collides with a built-in fastlane action of the same
  name and silently runs the wrong thing with no error.)
- Headline/keyword copy lives in `fastlane/Framefile.json`'s top-level
  `data` array, matched to screenshots by filename `filter` (a substring
  match against the full path, so the device-class prefix doesn't interfere).
- **Known limitation:** iPad 13" (2064x2752) cannot currently be framed —
  the installed frameit version's frame-artwork cache has no template for
  this resolution. `frame_app_screenshots` deliberately skips `iPad-13`
  rather than letting frameit raise; its screenshots stay bare and are not
  produced under `screenshots_framed/` at all. iPhone 6.9" and iPhone 6.5"
  both work. Revisit if upgrading Ruby/fastlane (see
  `fastlane/lib/frameit_device_patch.rb`'s comments) becomes worthwhile, or
  if Apple/frameit ships this frame later.
- **Per-locale copy override:** to give a locale different headline text
  (e.g. because German or Finnish text runs longer), drop a second
  `Framefile.json` inside that locale's screenshot folder —
  `fastlane/screenshots/<locale>/Framefile.json` — with the same `data`
  shape. `frame_app_screenshots` copies the locale-local file into the
  staging folder when present, else the shared top-level one. Its
  `background`/`font` values are still resolved against the shared
  `fastlane/backgrounds/` and `fastlane/fonts/` assets (the fastlane root),
  exactly like the top-level file — only `data` (the title/keyword text) is
  locale-specific; do not point a locale override's `background`/`font` at a
  path relative to the locale folder itself, since no such assets exist
  there. Always render and visually check for clipping before uploading;
  never auto-translate the English copy into a new locale's Framefile.
- Upload: `bundle exec fastlane upload_screenshots`. This lane does **not**
  delete any existing screenshot sets on App Store Connect (see the
  `overwrite_screenshots(false)` comment in `fastlane/Deliverfile`) —
  because we never produce framed iPad-13 output, an overwrite run would
  permanently delete iPad's live screenshots with nothing to replace them.
  It only adds new screenshot sets and skips already-uploaded files by
  checksum. To fully replace a stale iPhone screenshot set, clear it by hand
  in App Store Connect first.

## Out of scope by design

No XCUITest-driven capture, no HTML/CSS compositor, no auto-submit-for-review.
None of this runs from Xcode Cloud — always invoke manually or from a
standalone CI job.
