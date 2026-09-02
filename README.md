# NozzleCast

A local-first iOS companion app for Bambuddy — a self-hosted command center for Bambu Lab 3D
printers. NozzleCast talks directly to your own Bambuddy server; there is no NozzleCast backend,
account system, or analytics of any kind.

## Features

- **Fleet monitoring** — live status, progress, ETA, temperatures, fans, and AMS filament colors
  for every printer on your Bambuddy server, with a live camera feed (falling back to the job's
  cover/plate render when the camera isn't available).
- **AMS management** — tap a slot to assign inventory to it (with a material-mismatch warning
  matching Bambuddy's own UI); long-press a slot to re-read its RFID tag.
- **Filament inventory** — browse, edit, and scan-to-add spools (barcode or label-photo lookup via
  OFD/SpoolmanDB-Community), with type-or-pick fields matching Bambuddy's own input UX.
- **Push notifications** — Bambuddy's own alerts (progress, completion, errors, AMS/humidity
  warnings, etc.), delivered via your existing self-hosted ntfy → Firebase → APNs relay. Includes
  the camera snapshot Bambuddy attaches, an in-app history, and an unread badge on both the app
  icon and the in-app bell.
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

- **No "configure" push to AMS hardware.** NozzleCast can *assign* inventory to a slot (a
  database-only link, matching what Bambuddy's own UI does by default) but deliberately never
  sends the `configure` command that pushes real `ams_filament_setting` MQTT commands to the
  physical AMS — that's judged too risky for an unattended client action. See
  [ARCHITECTURE.md](ARCHITECTURE.md#assign-vs-configure).
- **No background polling.** The app only refreshes printer state when it's open (app launch,
  pull-to-refresh, or after an in-app action). Between those moments, Live Activity accuracy is
  carried by Bambuddy's own push events reaching the notification extension directly — not by any
  periodic background task.
