# fastlane/README.md (App Store Connect automation)

## Prerequisites

**Ruby >= 3.3** (macOS system Ruby is 2.6 and will not work). fastlane 2.240.1
itself only needs 3.1, but the committed `Gemfile.lock` resolves `excon 1.7.1`
and `rbs 4.2.0`, which both require >= 3.3 — so 3.3 is the real floor for this
lockfile. Those excon/aws-sdk-s3 versions are what clear GHSA-48rx-c7pg-q66r
and GHSA-2xgq-q749-89fq; the old Ruby 2.6 pin made both advisories permanently
unfixable, since no patched release resolves on 2.6.

Install a modern Ruby (`brew install ruby`, or any version manager), then
`bundle install` from `fastlane/`. CI pins `ruby-version: "3.4"` in
`.github/workflows/metadata-sync.yml`; the lockfile was last resolved locally
on Ruby 4.0.7. Both work — every gem in the lockfile was checked against 3.4,
and the lockfile carries no `RUBY VERSION` stanza and a generic `PLATFORMS:
ruby`, so it is portable. `BUNDLED WITH 4.0.20` means `ruby/setup-ruby` will
install bundler 4.x in CI (needs Ruby >= 3.2, satisfied by the 3.4 pin).

## Metadata sync

- Source of truth: `fastlane/metadata_config/<locale>/{app_info,version_info}.yml`.
- `bundle exec fastlane metadata_pull` — pull live values into the repo (use after App Review edits something, to reconcile, or to seed a locale for the first time).
- `bundle exec fastlane metadata_push dry_run:true` — see what would change without writing anything.
- `bundle exec fastlane metadata_push` — PATCH only the fields that differ. Never overwrites fields you haven't touched.
- Requires env vars: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`, `ASC_APP_ID`, optional `ASC_LOCALE` (default `en-US`). Create `fastlane/.env.asc` locally (gitignored) with these as `export` lines, then `source .env.asc` before running any lane — see the comment header in that file (or `.env.asc`'s own template if you haven't filled it in yet) for the exact format. Never commit this file; never paste its contents anywhere.

### Which App Store version metadata comes from

Apple's API splits editability by the app's current `AppStoreVersionState` (confirmed against Apple's own reference, `https://developer.apple.com/documentation/appstoreconnectapi/appstoreversionstate` — note this enum is itself deprecated in favor of `AppVersionState`, see the comment block in `fastlane/lib/metadata_sync/client.rb` for exactly what renames/drops that implies):

- **Editable** (`PREPARE_FOR_SUBMISSION`, `DEVELOPER_REJECTED`, `METADATA_REJECTED`, `INVALID_BINARY`, `WAITING_FOR_EXPORT_COMPLIANCE`, `REJECTED`) — `metadata_push` writes here. `name`/`subtitle` need a non-live `appInfo`; everything else needs one of these version states.
- **Readable-only** (`WAITING_FOR_REVIEW`, `IN_REVIEW`, `READY_FOR_REVIEW`, `ACCEPTED`, `PENDING_DEVELOPER_RELEASE`, `PENDING_APPLE_RELEASE`, `PROCESSING_FOR_APP_STORE`) — `metadata_pull`/dry-run diffing can see a version in these states, but `metadata_push` still raises `NoEditableVersionError` rather than guess which fields Apple would actually accept a PATCH for. Confirmed directly against a real app (NozzleCast, `WAITING_FOR_REVIEW`) that reads work correctly here; the rest of this category is reasoned by analogy, not individually tested.
- **Live** (`READY_FOR_SALE`) — confirmed directly against a real shipped app (ListNudge): **nothing** is editable here, not even manually through the App Store Connect UI. Reads still fall back to this state if nothing more specific exists.
- **Unclassified** (`PENDING_CONTRACT`, `PREORDER_READY_FOR_SALE`, `DEVELOPER_REMOVED_FROM_SALE`, `REMOVED_FROM_SALE`, `REPLACED_WITH_NEW_VERSION`, `NOT_APPLICABLE`) — an app whose only version sits in one of these raises `Client::NoVersionFoundError` loudly rather than silently returning an empty result (which `metadata_pull` would otherwise write straight through, wiping any already-seeded YAML — exactly what happened with `WAITING_FOR_REVIEW` before it was added to the readable-only set).

If you ever hit `NoVersionFoundError` or `NoEditableVersionError` against an app not covered by testing so far, that's the tool correctly refusing to guess — check the app's actual state in App Store Connect and treat it as new information to fold back into `client.rb`'s classification, not a bug to route around.

### CI

`.github/workflows/metadata-sync.yml` triggers on push to `main` touching `fastlane/metadata_config/**`, or manually via `workflow_dispatch` (Actions tab, or `gh workflow run metadata-sync.yml`). It needs 4 repo secrets — `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_APP_ID` (this app's own numeric App Store Connect ID), and `ASC_KEY_P8_BASE64` (the `.p8` file, base64-encoded) — set via `gh secret set <NAME> --repo <owner/repo> --body "$VALUE"` (never paste raw key material anywhere else). The workflow defaults to `dry_run:true` until a human deliberately removes it after confirming a clean dry run for that specific app — flipping it is a real production write from then on. Confirmed working end-to-end (both trigger paths, real secrets, real ASC API calls) against ListNudge and my-BedJet-Remote.

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
  both work. Still unsupported as of fastlane 2.240.1 (checked against its
  `frameit/lib/frameit/device_types.rb`, which has no 2064x2752 entry);
  revisit if Apple/frameit ships this frame later.
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
- **Critical gotcha — relative paths in `Deliverfile`/`Fastfile` config resolve
  against the project root, not `fastlane/`:** fastlane always `Dir.chdir`s to
  the project root (the parent of `fastlane/`) before running any lane,
  regardless of which directory you invoked `fastlane` from. A bare relative
  path like `screenshots_path("./screenshots_framed")` therefore resolves to
  `<project-root>/screenshots_framed`, not `<project-root>/fastlane/screenshots_framed`
  — the actual `Deliverfile` setting is `"./fastlane/screenshots_framed"` for
  exactly this reason. This bit us for real: with the un-prefixed path,
  `upload_screenshots` silently found zero local screenshots (an unrelated,
  coincidentally-existing empty directory at the project root satisfied the
  glob with nothing in it) and every downstream check in
  `deliver/lib/deliver/upload_screenshots.rb` trivially passed on zero files,
  so the lane printed "Successfully uploaded screenshots to App Store
  Connect" while uploading nothing — confirmed against a real app
  (my-BedJet-Remote) via a read-only ASC API query showing zero screenshot
  sets existed server-side despite that message. Any new relative path added
  to `Deliverfile` needs the `./fastlane/` prefix for the same reason; code
  written directly in `Fastfile.rb` is unaffected since it anchors paths with
  `File.join(__dir__, ...)`, and `__dir__` reflects the source file's own
  location rather than the process's current working directory.
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
