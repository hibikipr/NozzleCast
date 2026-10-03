# NozzleCast

A local-first iOS companion app for Bambuddy — a self-hosted command center for Bambu Lab 3D
printers. NozzleCast talks directly to your own Bambuddy server; there is no NozzleCast backend,
account system, or analytics of any kind.

## Features

- **Fleet monitoring** — live status, progress, ETA, temperatures, fans, and AMS filament colors
  for every printer on your Bambuddy server, with a live camera feed (falling back to the job's
  cover/plate render when the camera isn't available).
- **AMS management** — tap a slot to assign inventory to it (with a material-mismatch warning
  matching Bambuddy's own UI); long-press a slot to re-read its RFID tag. Works with Bambuddy's
  built-in inventory and with its Spoolman mode — the app follows whichever the server uses.
- **Filament inventory** — browse, edit, and scan-to-add spools (barcode or label-photo lookup via
  OFD/SpoolmanDB-Community), with type-or-pick fields matching Bambuddy's own input UX.
  Low-stock spools are flagged and filterable (using Bambuddy's own threshold), each spool shows
  its print-by-print usage, material number and suppliers, and Bambuddy's shopping list can be
  managed from the app, with running-low spools suggested for it.
- **Maintenance** — each printer's maintenance tasks from Bambuddy (what's due, what's coming up,
  last done), with a guide link where Bambuddy has one, and a way to record a task as done.
- **Print queue & history** — Bambuddy's print queue (start staged jobs, reorder, remove) and
  its print history with plate thumbnails, time, filament and cost. Finished prints ask "How did it
  come out?" (Good / Reject), in History and on the printer's screen; the answer is Bambuddy's own
  post-print verdict, so it feeds the same statistics as answering in its web UI.
- **Push notifications** — Bambuddy's own alerts (progress, completion, errors, AMS/humidity
  warnings, etc.), delivered via your existing self-hosted ntfy → Firebase → APNs relay. Includes
  the camera snapshot Bambuddy attaches, an in-app history, and an unread badge on both the app
  icon and the in-app bell.
  Without a Firebase config, the app falls back to reading Bambuddy's notification log, which
  covers every provider Bambuddy sends to (ntfy, Pushover, Discord, email…), and shows new alerts
  as local notifications. It checks on every refresh while open and on iOS background refresh
  otherwise, so alerts can arrive late; the API key needs `notifications:read`.
- **Live Activities** — a Dynamic Island / Lock Screen live progress card per printing printer,
  showing the plate cover render (or the latest live camera snapshot once one arrives), layer
  count, and nozzle/bed temperature — kept accurate even if a print finishes while the app is
  backgrounded.
- **Selectable app icon** — five alternates, switchable in Settings.

## Requirements

- A running Bambuddy server and an API key for it (Settings → API Keys in Bambuddy).
- Xcode with an iOS SDK matching this project's deployment target (see `project.pbxproj`).
- *(Optional, for push notifications)* a self-hosted ntfy server relaying through your own
  Firebase project, and that project's `GoogleService-Info.plist`. See
  [ARCHITECTURE.md](ARCHITECTURE.md#push-notifications) for why this is the integration path and
  what it assumes about your setup.

## Getting started

1. Open `NozzleCast.xcodeproj` in Xcode and run the `NozzleCast` scheme. Swift Package
   dependencies (Firebase, needed only for push) resolve automatically.
2. In the app: **Settings → Server** — enter your Bambuddy server URL and API key. Both are
   stored in the Keychain, never in UserDefaults or plain files.
3. *(Optional)* **Settings → Push Notifications** — import your `GoogleService-Info.plist`, then
   tap the Push Notifications row to request permission and subscribe. NozzleCast discovers the
   right ntfy topic automatically from Bambuddy's own `/api/v1/notifications/` config — there's
   nothing to type in.
4. Without a server configured, the app shows demo data so the UI is browsable on its own.

## Project structure

Three targets in one Xcode project:

| Target | Product type | Role |
|---|---|---|
| `NozzleCast` | App | The app itself — all UI, the Bambuddy API client, and the Live Activity/push managers that drive the other two targets. |
| `NozzleCastNSE` | Notification Service Extension | Turns Bambuddy's data-only push payloads into visible notifications, downloads and attaches the camera photo, and is the only thing that can update or finalize a Live Activity when the app is backgrounded. |
| `NozzleCastWidgets` | Widget Extension | Hosts the Live Activity's Dynamic Island and Lock Screen UI. |

See [ARCHITECTURE.md](ARCHITECTURE.md) for how these three talk to each other and why they're
split this way, plus the reasoning behind the rest of the app's design decisions.

## Notable non-features

- **No separate "configure" action for AMS hardware.** NozzleCast *assigns* inventory to a slot
  and never calls Bambuddy's slot-configure endpoint itself. Note that current Bambuddy versions
  push the assigned spool's filament settings to the printer as part of the assignment anyway, so
  an assignment does reach the AMS. See [ARCHITECTURE.md](ARCHITECTURE.md#assign-vs-configure).
- **No background polling.** The app only refreshes printer state when it's open (app launch,
  pull-to-refresh, or after an in-app action). Between those moments, Live Activity accuracy is
  carried by Bambuddy's own push events reaching the notification extension directly — not by any
  periodic background task.
