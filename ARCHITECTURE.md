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
- **`PushSharedStore` is a duplicated small Swift file, not real shared source** — near-identical
  copies in `NozzleCast/` and `NozzleCastNSE/` instead of one file with multi-target membership.
  This project uses `PBXFileSystemSynchronizedRootGroup` (each target's whole folder syncs
  automatically, no per-file pbxproj entries needed for ordinary source changes), which scopes a
  synced folder to one target; sharing one file across targets means hand-editing
  `PBXFileSystemSynchronizedBuildFileExceptionSet` entries, real pbxproj surgery. The App Group
  JSON this type serializes to only needs the two copies to stay *structurally* identical, not the
  literally same Swift type, so duplication with a comment pointing at the other copy is the
  lower-risk trade here. If these ever drift out of sync, that's a real bug to fix by hand, not
  something the compiler will catch across targets.
- **`PrintActivityAttributes` is *not* duplicated the same way — it can't be.** It used to be,
  identically to `PushSharedStore` above, on the same "structurally identical is enough" reasoning
  — which turned out to be wrong for this specific type. `ActivityKit` identifies an
  `ActivityAttributes` type by its *module-qualified* name, not just its shape: three structurally
  identical `PrintActivityAttributes` compiled separately into three targets' own modules
  (`NozzleCast.PrintActivityAttributes`, `NozzleCastNSE.PrintActivityAttributes`, ...) are three
  *different* types as far as `Activity<PrintActivityAttributes>.activities` is concerned — an
  activity started under one module's identity is invisible to a process compiled with a
  different one. This was a real, confirmed bug (see Live Activities below), fixed by moving the
  type into `NozzleCastShared`, a local Swift package all three targets depend on, so there is
  really only one compiled `PrintActivityAttributes` for ActivityKit to ever see.

## Live Activities

The Live Activity is entirely relay-driven today — [`nozzlecast-relay`](https://github.com/hibikipr/nozzlecast-relay),
a small self-hosted Node.js service the user runs alongside Bambuddy (not a NozzleCast-operated
service, matching this project's "no backend of NozzleCast's own" principle), starts it, updates
it, and ends it, all via direct APNs pushes. The app's own local creation/update code
(`PrintLiveActivityManager`) still exists and still works, but only ever runs when the app happens
to be foregrounded — which is why it can't be the primary mechanism for something that has to
keep working with the phone locked.

- **Local discovery of a push-to-start-created activity does work — an earlier version of this
  document said the opposite, and was wrong.** It previously asserted, as confirmed fact, that
  neither the app nor the notification extension could *ever* locally discover such an activity:
  "not a timing race — confirmed empty via both `Activity<PrintActivityAttributes>.activities`
  and `.activityUpdates` across an entire real print." That observation was real, but the
  explanation was not. Push-to-start was silently broken at the time (the relay sent a
  module-qualified `attributes-type`, which APNs accepts with a 200 and iOS drops on the device
  with no error anywhere but `liveactivitiesd`'s log), so **no activity was ever being created**.
  Discovery found nothing because there was nothing to find.

  Confirmed 2026-09-07, once `attributes-type` was corrected to the bare
  `PrintActivityAttributes`: `.activityUpdates` delivered the push-to-start-created activity to
  the app, and `/register-activity` registered its per-activity token ~3.5s after print start.
  See nozzlecast-relay's ARCHITECTURE.md for the relay-side timeline.

  What *is* still true and unrelated to any of this:
  `ActivityAuthorizationError.visibility` ("The app tried to start the Live Activity while it was
  in the background") makes `Activity.request()` a non-starter for *starting* an activity while
  locked — which is why push-to-start exists at all. And the widget extension is fed an
  already-resolved `ActivityViewContext` by the system at render time, so it renders correctly
  regardless of what any other process can see.

  **The relay architecture below is unchanged and is still the right design** — pushing
  `update`/`end` straight through APNs does not depend on any local process running, which is
  more robust than local discovery either way. Only the stated justification was wrong, not the
  decision. Treat "local discovery is impossible" as retracted; do not reason from it.
- **Starting**: the relay watches for a print-start event by polling Bambuddy's own
  `/api/v1/printers/` + `/status` and diffing raw `gcode_state` transitions
  (`BambuddyPoller`/`printerStateClassifier.js`) — and sends a push-to-start APNs request straight
  to Apple, bypassing the app/NSE entirely. A second trigger that classified Bambuddy's ntfy alert
  *titles* was removed from the relay on 2026-09-07: it could only ever see the events Bambuddy
  chose to notify on (start, 25/50/75%, end), so pause, resume and HMS issues were invisible to
  it, and running it alongside the poller wiped the per-activity push token the app had just
  registered. Unrelated to the app's own ntfy → Firebase → NSE notification path, which stays.
  `PushNotificationManager` observes `Activity<PrintActivityAttributes>.pushToStartTokenUpdates`
  and POSTs each token to the relay's `/register` endpoint.
- **Updating and ending**: these go straight through APNs, per-activity, bypassing the app and
  extension — not because local discovery is impossible (see the retraction above), but because a
  path that needs no local process running at all is strictly more robust for something that has
  to keep working with the phone locked. Apple's docs promise the system wakes the
  app specifically to deliver a fresh per-activity `pushToken` when an activity starts via
  push-to-start, independent of whether the app is resident. `PushNotificationManager` observes
  every activity's own `pushTokenUpdates` (discovered via `.activityUpdates`) and POSTs each
  token, keyed by `printerID`, to the relay's `/register-activity` endpoint. The relay pushes
  `update`/`end` events directly to that token as Bambuddy's real state changes — no local
  discovery needed on either side. This observation starts from `configureFirebaseIfNeeded()` at
  launch (gated on `RelayConfigStore.isConfigured`) and is re-armed from `RelayConnectionSheet`
  when the relay is configured post-launch — **confirmed live 2026-09-05: the re-arm call was
  missing for this specific observer** (only the push-to-start observer was re-armed), so
  `/register-activity` never fired at all on any process whose first `configureFirebaseIfNeeded()`
  ran before the relay was configured, with no way to recover short of a full relaunch. Fixed by
  adding the matching call in `RelayConnectionSheet.save()`.
- **Anything read at launch can be unreadable at launch, and "unreadable" is not "absent"
  (confirmed live 2026-09-08).** An iPad was power-cycled, launched in the background before its
  first unlock, and showed blank Bambuddy settings for the rest of that process's life — the
  credentials were never gone, and force-quitting while unlocked brought them straight back.
  Keychain items here are `kSecAttrAccessibleAfterFirstUnlock` and `RelayConfigStore`'s file sits
  in Application Support (protected until first unlock), so both are unreadable in that window,
  and both used to report it as "not configured."

  The expensive consequence was not the blank settings, it was that
  `startObservingActivityKitTokens()` ran **once**, from `didFinishLaunching`, behind a
  `RelayConfigStore.isConfigured` guard. A launch while locked armed neither token observer, and
  nothing retried — so for that whole process no push-to-start token was observed and no activity
  token registered, the relay went on pushing to a stale token, APNs returned a genuine 200, and
  no Live Activity was ever created. What the user saw was the "open the app" fallback banner
  firing over and over. Two days went into chasing that, via a payload-size theory, an
  `attributes-type` theory, and `liveactivitiesd`'s real-but-unrelated push budget, before the
  cause turned out to be a guard that ran too early exactly once.

  The rules that follow, both now enforced in code: **arm on every activation, not at launch** (a
  foreground app is by definition on an unlocked device, so it is the one moment these stores are
  guaranteed readable), and **never map an unrecognized read failure onto "absent"** —
  `KeychainStore.read` returns `notFound` and `unavailable` as distinct answers and treats
  anything it doesn't recognize as the latter.
- **A token the relay drops has to be re-sendable, and an async sequence alone cannot do that
  (confirmed live 2026-09-08).** An iPad and a phone on the same build, same print: only the iPad
  got a Live Activity, while the phone showed the "open the app" fallback. The relay deletes a
  push-to-start token on a 400/410, and the app only ever registered one when
  `pushToStartTokenUpdates` yielded — which happens when iOS issues or rotates a token, not on
  launch and not on demand. So a deleted token that never rotates again is never re-sent, the
  relay has nothing to push push-to-start to, and every subsequent print silently creates no
  activity. The iPad worked only because a TestFlight update had issued it a fresh token.
  Re-arming the observer cannot fix this — `pushToStartObservationTask` is already non-nil, so the
  guard returns immediately. `recheckPushToStartToken()` reads
  `Activity<PrintActivityAttributes>.pushToStartToken` directly instead, forced on every
  background wake so a dropped token heals by the next print. Same reasoning as
  `recheckActivityTokens()`, which had had this treatment for the *per-activity* token all along —
  the asymmetry was the bug.
- **Background wake is a secondary fallback, not the primary fix.** The app also registers its
  plain APNs device token (`/register-device`); the relay sends it a `content-available` push
  alongside every push-to-start, which runs `PrintLiveActivityManager.sync()` in the background —
  this is what lets a locally-created/backgrounded activity stay in sync even without a
  foreground, but the per-activity push path above is what actually carries the print end-to-end
  while the phone stays locked and the app never runs at all.
- **Content is real Bambuddy telemetry, not text parsed from a notification.** The relay calls
  Bambuddy's own `GET /api/v1/printers/{id}/status` directly (`BambuddyClient`/
  `bambuddyEnrichment.js`) for progress, layer count, nozzle/bed temps, job name, and remaining
  time — the same API this app's own `BambuddyAPIClient` uses — rather than regex-parsing ntfy
  alert text. Enrichment failures fail open independently *per field* (numeric telemetry,
  `coverImage`, and `liveSnapshot` each get their own try/catch): a flaky camera endpoint costs
  exactly that one image, never the whole update. `estimatedEndAt` specifically distrusts an
  implausible `remaining_time` (Bambuddy reports `0`–`3`s at print start before it's computed a
  real estimate, and for at least one test G-code file, seemingly never computes one at all) —
  when rejected, the field is simply omitted rather than shown wrong; the widget's fallback
  (below) renders cleanly either way.
- **The issue badge mirrors Bambuddy's own HMS severity scale, confirmed from its frontend
  source** (`HMSErrorModal.tsx`'s `getSeverityInfo`), not guessed: severity 1/2 (Fatal/Serious) →
  `issueSeverity: "error"`, severity 3 (Warning) → `"warning"`, severity 4/anything else (Info) →
  no badge at all. This last case is load-bearing, not incidental: a persistent "Developer Mode
  not enabled" advisory on this deployment is genuine severity 5, and briefly shipped as a
  Live-Activity-wide false "Error" before the severity floor (and Bambuddy's own `hms_errors`
  presence-flakiness, needing a debounce) were both accounted for. `AppStore.mapState` computes
  the app's *own* printer-list status the same way, independently, for the same reason —
  see below.
- **A printer only shows as `Error` (app) or gets a "Failed" label (relay) when a real qualifying
  HMS issue is actually attached — not just because the raw state string says `FAILED`.**
  Confirmed against Bambuddy's own frontend (`classifyPrinterStatus`, `PrintersPage.tsx`): "FAILED
  without an active HMS error is the printer's terminal state after any unsuccessful end —
  including user-cancellations. Treat the same as FINISH... only escalate to error when an HMS
  code is actually attached." Before this, `AppStore.mapState` mapped raw `FAILED` straight to
  `.error` unconditionally, so a printer sitting idle after any stopped print showed "Error"
  forever. The relay applies the same principle to the Live Activity's terminal `stateLabel`:
  "Failed" only when a real issue was confirmed active going into the transition
  (`priorIssueSeverity`, captured from the poll *before* the FAILED tick — Bambuddy resets
  `progress`/`layer_num` to 0 the instant `gcode_state` becomes `FAILED`, so both the label
  decision and the final progress shown use the last-good pre-transition snapshot, not a fresh,
  already-reset query); otherwise it says "Stopped" — deliberately not "Complete" (implies
  success, wrong for a print the user manually ended) and not "Failed" (implies a fault that
  isn't confirmed).
- **The widget shows the actual reported progress, not a time-interpolated estimate — and a
  clock time, not a countdown.** A locally interpolated `elapsed / (estimatedEndAt - startedAt)`
  fraction drifts from the real percentage whenever print speed isn't linear (a slow first layer,
  say), and — separately — a Live Activity's rendering only guarantees continuous on-device
  refresh for a specific short list of primitives (date-styled `Text`, `ProgressView(timerInterval:)`);
  an arbitrary `TimelineView`, which is what the interpolation used, isn't reliably re-evaluated
  between pushes in that context, so it likely wasn't buying the smoothness it was written for
  either. The progress bar and percentage both read `state.progress` directly now. The former
  countdown-timer display is a localized "Est. finish" clock time instead
  (`Text(_:style: .time)`, a stopwatch icon in place of a text label), which is both more useful
  and, being date-styled, one of the primitives that *does* refresh live.
- **Corrections happen on a fixed interval, not on Bambuddy's own progress milestones.** The
  relay's poll trigger only reacts to real `gcode_state` transitions (start/pause/resume/
  finish/failed) and a new HMS issue — "progress crossed 50%" isn't one of those. A periodic
  correction (`LIVE_ACTIVITY_CORRECTION_INTERVAL_MS`, currently 1 minute — a short print can
  finish well inside the old 10-minute default, during which nothing but a state-change event
  would ever refresh the display) re-fetches and re-pushes fresh telemetry to any active print
  with no other event, filling the gap between real transitions.
- **The `UIGraphicsImageRenderer` scale trap** (relevant to the app's own local downscale
  helpers, which the relay's separate `sharp`-based downscale — see the relay's own docs — doesn't
  share the same failure mode for but does replicate the same output caps for). Both pin
  `format.scale = 1` explicitly: without it, `UIGraphicsImageRenderer(size:)` defaults to the
  device's screen scale (2x/3x), so a "40pt" thumbnail was actually rasterizing at up to 9x the
  intended pixel count — no amount of JPEG quality reduction could compress that back down under
  budget, and every real photo was silently rejected by the size guard.
- **Why the images are capped so small (under ~1.3KB each).** ActivityKit's real budget for the
  *whole* serialized `ContentState` is close to 4KB, and a `Data` field costs ~33% more once
  base64-encoded into that JSON on top of it. Blowing that budget doesn't fail gracefully — the
  system ends the Live Activity outright rather than just dropping the update — so every guard
  here fails closed: if compression can't hit the target, no image is sent for that field rather
  than risking the activity.
- **`await`, never a bare `Task { }`, for `activity.update()`/`.end()`.** Two real, confirmed bugs
  came from this: in the app, `AppStore.refresh()` returning before an un-awaited update Task
  finished meant the update could be dropped if the app was backgrounded moments later; in the
  extension, it was close to guaranteed to fail, since the extension process is liable to be
  terminated shortly after `deliver(content)` is called. Both `PrintLiveActivityManager.sync()`
  and the extension's `updateLiveActivity()` are `async` specifically so their callers can await
  them fully before returning.
- **The extension's own local end/update logic is a rarely-exercised fallback.** It's correct if
  it finds a matching activity, and real ending happens via the relay's per-activity push
  regardless. How often it actually matches a push-to-start-created activity is now an open
  question rather than a settled "never": the claim that it could never find one rested on the
  retracted local-discovery finding above. The extension is still a fresh OS process per push
  with no state carried between invocations, so it plausibly still finds nothing — but that has
  not been re-measured since push-to-start started working. Kept in place either way.
- **Printer matching by normalized name text, not an ID, on both sides of the relay boundary.**
  ntfy/Bambuddy carry no printer identifier usable across process/service boundaries, only a name
  — and inconsistently, sometimes the display name ("Vic H2C") and sometimes the printer's raw
  slug ("vic-h2c"). `PrintActivityAttributes.normalizedID` strips everything but letters/digits
  before comparing; the relay's own `normalizedID()` (`parsing.js`) does the same thing
  independently, so a name computed on either side of the process boundary matches.

  `RelayConfigStore`/`RelayConnectionSheet` hold the relay's URL and auth secret, entered once in
  Settings.

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
