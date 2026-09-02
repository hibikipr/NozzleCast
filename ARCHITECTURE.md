# Architecture & design decisions

This document is the "why," not the "what" — for what each file does, read the file (they're
commented where the reasoning isn't obvious from the code itself). This covers decisions that
shaped the app and are easy to second-guess without the context behind them.

## Overall shape

- **SwiftUI + `@Observable`, one store.** `AppStore` is the single source of truth for printers,
  spools, and connection state; every view reads it via `@Environment(AppStore.self)`. There's no
  Redux-style action/reducer layer — `AppStore`'s methods (`refresh()`, `assignSpool`, `clearPlate`,
  etc.) mutate `@Observable` state directly and views re-render. For an app this size, an extra
  indirection layer would cost more than it'd save.
- **No backend of NozzleCast's own.** Every API call goes straight to the user's Bambuddy server.
  This keeps the trust model simple: your printer data goes exactly where you already trust it to
  go (your own Bambuddy instance), and nowhere else.
- **Keychain-only credentials.** The Bambuddy server URL and API key both live in the Keychain
  (`KeychainStore.swift`), never in `UserDefaults` or a plain file. This was tightened partway
  through development after finding the server URL specifically had been left in `UserDefaults`
  while the API key was already correctly in the Keychain — an inconsistency, not a deliberate
  choice, fixed with a one-time migration on first launch after the fix.
- **Mock data as the zero-config state**, not an error state. With no server configured, the app
  shows `MockData` printers/spools rather than an empty or broken screen, so the UI is browsable
  immediately.

## Push notifications

NozzleCast doesn't run its own push infrastructure. Instead it reuses the same
Firebase Cloud Messaging → APNs pipeline the user's own separate ntfy iOS app already uses against
their self-hosted ntfy server — the same server Bambuddy is already configured to publish alerts
to. Concretely:

- **Firebase is configured at runtime**, not baked into the binary. The user imports their own
  `GoogleService-Info.plist` (validated in `FirebaseConfigStore`, including the `GOOGLE_APP_ID`
  regex check Firebase itself needs or it traps with an uncatchable `NSException`), stored in
  Application Support. There is no NozzleCast-specific Firebase project — it rides on the same
  project as the user's ntfy app.
- **Topic discovery is automatic.** `AppStore.discoverAndSubscribeNtfy()` calls Bambuddy's own
  `GET /api/v1/notifications/` and finds its `ntfy` provider's `server`/`topic`/`auth_token` — the
  user never types a topic name in.
- **FCM topic name.** ntfy's real behavior (confirmed against the actual server, not assumed):
  a client subscribes to the *raw* topic name if the ntfy server matches the subscribing app's own
  bundled default server, or to `SHA256(normalizedBaseUrl + "/" + topic)` otherwise. The first
  implementation always hashed, which turned out wrong for this specific setup — the user's own
  ntfy app has `ntfy.townsville.cc` baked in as *its own* default server, so per that same rule it
  subscribes to the raw topic. `PushNotificationManager` mirrors that by comparing against the
  known server rather than hashing unconditionally. This is the one piece of this pipeline that's
  genuinely tied to this specific deployment rather than being generically correct — if the ntfy
  server ever changes, this constant needs to change with it.
- **The notification extension does real work, not just formatting.** Bambuddy's push payload is
  data-only (no `aps.alert`), so `NozzleCastNSE` builds the entire visible notification: parses
  ntfy's `attachment` field (present on most Bambuddy print events, confirmed against live traffic
  — both the flat `attachment_url` key in the push payload and the nested
  `{"attachment":{"url":...}}` shape in the REST poll fallback), downloads the photo, attaches it
  to the banner, and feeds it into the matching Live Activity (see below). It also handles ntfy's
  `poll_request` event (privacy-preserving relays sometimes omit content from the push and expect
  a follow-up `GET {server}/{topic}/json?poll=1&id=...` instead).
- **Unread tracking lives in the shared store, not the system's notification center.** Each
  history entry has an `isRead: Bool?` — `Bool?` rather than a plain `Bool` with a default,
  because a non-optional property's synthesized `Decodable` doesn't apply its default when the key
  is missing from older stored JSON; it throws instead, and since the whole array decode is one
  `try?`, that would have silently wiped the entire history for anyone who had one from before
  this field existed. `nil` reads as "predates this feature," not as unread.

## Shared state between three processes

The main app, the notification extension, and the widget extension are three separate processes.
Two mechanisms bridge them, chosen for how small the actual needs are:

- **`PushSharedStore`** — a flat JSON file (plus a folder of JPEGs) in an App Group container,
  covering the ntfy config the extension needs for its poll fallback and the notification history
  log. This is *not* a general-purpose sync mechanism; it's sized for "one ntfy subscription and a
  short list of recent notifications," which is what the app actually needs. Core Data/CloudKit
  would be solving a problem this app doesn't have.
- **Duplicated small Swift files, not real shared source.** `PushSharedStore` and
  `PrintActivityAttributes` each exist as near-identical copies in more than one target
  (`NozzleCast/`, `NozzleCastNSE/`, `NozzleCastWidgets/`) instead of one file with multi-target
  membership. This project uses `PBXFileSystemSynchronizedRootGroup` (each target's whole folder
  syncs automatically, no per-file pbxproj entries needed for ordinary source changes), which
  scopes a synced folder to one target; sharing one file across targets would mean hand-editing
  `PBXFileSystemSynchronizedBuildFileExceptionSet` entries, which is exactly the kind of pbxproj
  surgery most likely to quietly corrupt the project. ActivityKit and the App Group JSON only need
  the types to be *structurally* identical Codable shapes across the process boundary, not the
  literally same Swift type — so duplication with a comment pointing at the other copies is the
  lower-risk trade. If these ever drift out of sync, that's a real bug to fix by hand, not
  something the compiler will catch across targets.

## Live Activities

- **Two image sources, not one.** `ContentState` carries both `coverImage` (the sliced-plate
  render, fetched once by the app when a print starts — it's static for the whole job, so it's
  cached via `PrintLiveActivityManager.hasCoverImage` and never re-fetched) and `liveSnapshot`
  (Bambuddy's live camera frame, pushed independently by the notification extension whenever a
  photo-bearing event arrives). The widget prefers the live snapshot and falls back to the cover
  render, so there's almost always a real image rather than a generic icon.
- **The `UIGraphicsImageRenderer` scale trap.** Both image downscale helpers pin
  `format.scale = 1` explicitly. Without it, `UIGraphicsImageRenderer(size:)` defaults to the
  device's screen scale (2x/3x), so a "40pt" thumbnail was actually rasterizing at up to 9x the
  intended pixel count — no amount of JPEG quality reduction could compress that back down under
  budget, and every real photo was silently rejected by the size guard. This was chased through
  three rounds of "raise the byte cap" before the actual cause was found by instrumenting the
  compression loop live against a real image on-device; the byte caps that remain now have real
  headroom rather than being load-bearing.
- **Why the images are capped so small (under ~1.3KB each).** ActivityKit's real budget for the
  *whole* serialized `ContentState` is close to 4KB, and a `Data` field costs ~33% more once
  base64-encoded into that JSON on top of it. An earlier, looser cap (3KB for one image) blew that
  budget and the system ended the Live Activity outright rather than just dropping the update —
  so the guard fails closed: if compression can't hit the target, no image is sent for that update
  rather than risking the activity.
- **`await`, never a bare `Task { }`, for `activity.update()`/`.end()`.** Two real, confirmed bugs
  came from this: in the app, `AppStore.refresh()` returning before an un-awaited update Task
  finished meant the update could be dropped if the app was backgrounded moments later (exactly
  the common "glance at the app, then lock the phone to check the Lock Screen" flow); in the
  extension, it was close to guaranteed to fail, since the extension process is liable to be
  terminated shortly after `deliver(content)` is called, and a bare `Task { }` there had no
  guarantee of running to completion before that happened. Both `PrintLiveActivityManager.sync()`
  and the extension's `updateLiveActivity()` are `async` specifically so their callers can await
  them fully before returning.
- **The extension is what actually ends a finished Live Activity**, not the app. Since the app only
  refreshes in the foreground, a print completing overnight with the app backgrounded would
  otherwise leave the Live Activity frozen on "Printing" indefinitely — confirmed as a real bug in
  practice. Bambuddy's completion/failure/stop pushes arrive via APNs regardless of app state, so
  the extension detects them by title (substring-matching "complete"/"fail"/"cancel"/"stop" — the
  only titles confirmed against live traffic are the "complete" family; the others are inferred
  from Bambuddy's own event-flag names) and finalizes the activity itself.
- **Printer matching by normalized name text, not an ID.** ntfy messages carry no printer
  identifier, only a name embedded in the title/body — and inconsistently, sometimes the display
  name ("Vic H2C") and sometimes the printer's raw slug ("vic-h2c"). Both the extension's activity
  matching and its terminal-state detection strip everything but letters/digits before comparing,
  which matches either form.
- **Starting a Live Activity while the phone is locked doesn't work, and can't be patched from
  where it lives today.** ActivityKit only allows `Activity.request` (starting a *new* activity)
  to succeed while the containing app is in the foreground — confirmed via Apple's own
  `ActivityAuthorizationError.visibility` ("The app tried to start the Live Activity while it was
  in the background"). `NotificationService.updateLiveActivity` tries to start one from the
  extension when a "print started" push arrives with no matching activity, but that call throws
  `.visibility` whenever the phone is locked or the app is backgrounded — i.e. exactly the case
  it was written for. It's left in as a harmless no-op fallback for the rare case the app happens
  to already be foreground, but it isn't reliable. What currently mitigates this: `MonitorView`
  triggers `AppStore.refresh()` (which calls `PrintLiveActivityManager.sync()`) on every
  `scenePhase` transition to `.active`, so the missing activity catches up the moment the app is
  next opened or unlocked into — but there's still a real gap between the print starting and the
  phone being unlocked.

  The actual fix is ActivityKit's **push-to-start** mechanism: observe
  `Activity<PrintActivityAttributes>.pushToStartTokenUpdates`, and have something send a
  properly-shaped APNs payload directly (`"event": "start"` plus `attributes-type`/`attributes`/
  `alert`, per Apple's ActivityKit push notification spec) whenever Bambuddy reports a print
  starting. This can't be bolted onto the current ntfy → Firebase → NSE pipeline — push-to-start
  notifications go straight to APNs and are handled by the system before any app code runs, so the
  NSE never sees them. It needs a component that (a) receives the push-to-start token from the app
  and (b) can call APNs directly the moment Bambuddy's "print started" event fires. Given this
  project's "no backend of NozzleCast's own" principle, the least-bad shape is probably a small,
  self-hosted relay the user runs alongside Bambuddy/ntfy — not a NozzleCast-operated service —
  but that's a real new moving part, not a client-side change, which is why it's documented here
  rather than implemented.

## AMS and inventory

- **`assign` vs `configure`.** Bambuddy exposes two distinct operations: *assign* (a
  database-only link between an inventory spool and a slot — `POST /inventory/assignments`) and
  *configure* (`POST /printers/{id}/slots/{ams}/{tray}/configure`, which sends real
  `ams_filament_setting`/`extrusion_cali_sel` MQTT commands to the physical AMS hardware).
  NozzleCast implements only *assign*, plus a "Material Mismatch" warning that mirrors Bambuddy's
  own dialog when the assigned spool's material doesn't match what the printer's RFID/manual entry
  reports. Pushing real hardware commands from a mobile client felt like a materially different
  risk level than a database link, so it was scoped out deliberately rather than by omission.
- **RFID re-read is a long-press, not a tap.** Tapping an AMS slot opens the assign/filament
  picker (the common action); long-press pops up a context menu with "Re-read RFID" (calling
  Bambuddy's `POST /printers/{id}/ams/{ams}/slot/{tray}/refresh`), mirroring how Bambuddy's own
  web UI separates the two interactions.
- **`Spool.material` is a raw `String`, not an enum.** It started as a small closed `enum
  FilamentMaterial`, but Bambuddy accepts arbitrary material strings (`"PLA"`, `"PETG-HF"`,
  `"Support for PLA"`, ...) and the edit-spool flow needed type-or-pick fields (type freely, or
  pick from a suggestion list) matching Bambuddy's own input UX for material/brand/subtype — which
  isn't representable by a fixed enum. `FilamentMaterial` still exists as a coarse bucketing helper
  for filtering, but it's derived from the string, not the source of truth.

## App icon

Five alternates, registered via `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS = YES` rather
than hand-written `CFBundleIcons`/`CFBundleAlternateIcons` Info.plist entries — Xcode generates
those automatically from the asset catalog's icon sets (any additional `.appiconset` beyond the
primary one becomes a selectable alternate, named after its folder), which is far less error-prone
than maintaining that nested plist structure by hand alongside a `GENERATE_INFOPLIST_FILE = YES`
project. The primary icon (what a fresh install gets, and what "Default" represents in the picker)
can change over time — it currently is "Steel" — without needing any Info.plist changes, only
swapping which image sits in `AppIcon.appiconset`.
