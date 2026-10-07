# NozzleCast

A local-first iPhone and iPad companion app for [Bambuddy](https://github.com/karliky/bambuddy) — a
self-hosted command center for Bambu Lab 3D printers. NozzleCast talks directly to your own
Bambuddy server; there is no NozzleCast backend, account system, or analytics of any kind.

[Download on the App Store](https://apps.apple.com/us/app/nozzlecast/id6807135097) ·
[Website](https://nozzlecast.townsville.cc)

## Features

- **Fleet monitoring** — live status, progress, ETA, temperatures, fans, and AMS filament colors
  for every printer on your Bambuddy server, with a live camera feed (falling back to the job's
  cover/plate render when the camera isn't available). Printer state and HMS alerts are shown
  separately, with Bambu's own alert levels.
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
- **Alerts** — Bambuddy's own alerts (print progress and completion, errors, AMS/humidity
  warnings…) as notifications, with the camera snapshot Bambuddy attaches, an in-app history, and
  an unread badge on the app icon and the in-app bell. See
  [How alerts and Live Activities reach your phone](#how-alerts-and-live-activities-reach-your-phone).
- **Live Activities** — a Lock Screen / Dynamic Island progress card per printing printer, showing
  the plate render (or the live camera frame, if you allow it), layer count, and nozzle/bed
  temperature.
- **AMS Colors widget** — a Home Screen widget (small, medium, or large) showing the filament in
  each AMS unit across your printers.
- **Selectable app icon** — five alternates, switchable in Settings.

## Setting up the app

Everything is configured in the app's **Settings** tab. Without a server configured, the app shows
demo data so you can look around first.

### 1. Printer Server (required)

Tap **Server** and enter:

| Field | What to enter |
|---|---|
| **Server URL** | The address of your Bambuddy server, e.g. `https://bambuddy.example.com` or its address on your local network. Your phone must be able to reach it — at home, or remotely through a VPN or reverse proxy. |
| **API Key** | A key created in Bambuddy under **Settings → API Keys**. |

Tap **Save & Test Connection**. Once connected, the footer lists the permissions your key has.
Give the key the permissions for what you want to do:

| Bambuddy permission | Needed for |
|---|---|
| Read Status (`printers:read`) | Everything — printer status, camera, queue, history. Required. |
| Manage Inventory (`inventory:create` / `inventory:update`) | Adding and editing spools, and assigning spools to AMS slots. |
| Printer Control (`printers:control`) | Actions that operate your printers. |
| `notifications:read` | Alerts on the App Store version (see below). Settings shows *Can't read alerts* without it. |

The server URL and API key are stored in the iOS Keychain, never in plain files.

### 2. Alerts

Tap **Alerts** and allow notifications. NozzleCast then reads the alerts Bambuddy has sent to your
notification providers (ntfy, Pushover, Discord, email…) from Bambuddy's notification log, and
shows new ones as notifications. **Notification History** lists past alerts.

### 3. Live Activities

- **Live Activities** — turn on to get the progress card while a printer prints.
- **Camera Preview on Lock Screen** — shows the printer's live camera frame on the card. Turn it
  off if you don't want that visible to anyone who picks up your phone.

### 4. Instant push and the relay (self-built app only)

These only work if you [build NozzleCast yourself](#building-it-yourself). In Settings → Push
Notifications:

| Row | What to provide |
|---|---|
| **Firebase Config** | The `GoogleService-Info.plist` of the Firebase project your ntfy server publishes through. Once it's imported, the two rows below replace **Alerts**. |
| **Push Notifications** | Tap to allow notifications and subscribe. NozzleCast reads the ntfy topic from Bambuddy's own notification settings, so there's nothing to type. Shows *Enabled* when subscribed. |
| **Push-to-Start Relay** | The URL of your [nozzlecast-relay](https://github.com/hibikipr/nozzlecast-relay) (e.g. `https://relay.example.com`) and its **Registration Secret** — the relay's `RELAY_AUTH_SECRET`. Shows *Registered* once the relay has accepted the phone's token. |

## How alerts and Live Activities reach your phone

| | App Store app | Self-built + Firebase | Self-built + Firebase + relay |
|---|---|---|---|
| **Alerts** | Read from Bambuddy's notification log when the app refreshes, and in the background when iOS allows — so they can arrive late. | Instant push via your ntfy server → Firebase → APNs. | Same as Firebase. |
| **Live Activities** | Start and update only while the app is open. | Start only while the app is open; also updated when an alert push arrives. | Started the moment a print begins — even with the phone locked — then updated and ended by the relay through APNs. |

The instant options need Apple Push Notification service (APNs) credentials for the app's bundle
ID, and Apple only issues those to the developer account that signs the app. That's why they
require building NozzleCast yourself with your own Apple Developer account.

**[nozzlecast-relay](https://github.com/hibikipr/nozzlecast-relay)** is a small open-source
service you self-host next to Bambuddy. It polls Bambuddy for print state changes and sends
Live Activity start, update and end pushes straight to Apple, so Live Activities stay accurate
without the app running. See its README for configuration (your APNs key, team ID, the bundle ID
of your build, and your Bambuddy URL and API key) and deployment.

## Building it yourself

### Requirements

- Xcode with the iOS 26 SDK (the deployment target is iOS 26.0).
- A running Bambuddy server and an API key for it.
- For instant push or the relay: a paid Apple Developer account, a Firebase project with your APNs
  key uploaded, and a self-hosted ntfy server that publishes to that Firebase project.

### Steps

1. Open `NozzleCast.xcodeproj` and run the `NozzleCast` scheme. Swift Package dependencies
   (Firebase, used only for push) resolve automatically.
2. Under **Signing & Capabilities**, pick your team for all three targets. To run on a device,
   change the bundle IDs (`com.victormanuel.NozzleCast` and its `.NozzleCastNSE` /
   `.NozzleCastWidgets` extensions) and the App Group (`group.com.victormanuel.NozzleCast`) to your
   own. The App Group is also hard-coded in `PushSharedStore.swift` (app and NSE) and in
   `NozzleCastShared/Sources/NozzleCastShared/AMSWidgetSnapshot.swift`.
3. For instant push with your own ntfy server, update `knownNtfyDefaultBaseUrl` in
   `PushNotificationManager.swift` — see
   [ARCHITECTURE.md](ARCHITECTURE.md#push-notifications) for why the topic name depends on it.
4. Set up the app as described in [Setting up the app](#setting-up-the-app).

See [CONTRIBUTING.md](CONTRIBUTING.md) for running the tests.

## Project structure

Three targets in one Xcode project:

| Target | Product type | Role |
|---|---|---|
| `NozzleCast` | App | The app itself — all UI, the Bambuddy API client, alerts, and the Live Activity and push managers (including registering push tokens with the relay). |
| `NozzleCastNSE` | Notification Service Extension | Turns Bambuddy's data-only push payloads into visible notifications, downloads and attaches the camera photo, and feeds it into the matching Live Activity. |
| `NozzleCastWidgets` | Widget Extension | The Live Activity's Lock Screen and Dynamic Island UI, and the AMS Colors widget. |

See [ARCHITECTURE.md](ARCHITECTURE.md) for how these talk to each other and to the relay, and the
reasoning behind the app's design decisions.

## Notable non-features

- **No separate "configure" action for AMS hardware.** NozzleCast *assigns* inventory to a slot
  and never calls Bambuddy's slot-configure endpoint itself. Current Bambuddy versions push the
  assigned spool's filament settings to the printer as part of the assignment anyway, so an
  assignment does reach the AMS. See [ARCHITECTURE.md](ARCHITECTURE.md#assign-vs-configure).
- **No background polling of printer state.** The app only refreshes printers when it's open (app
  launch, pull-to-refresh, or after an in-app action). The only background work is the alert check
  on the App Store version, run when iOS allows. With the relay, Live Activities are kept current
  by the relay's own pushes, not by the app.

## Contributing

Bug reports, fixes, and features that fit the app's scope are welcome — see
[CONTRIBUTING.md](CONTRIBUTING.md). Please report security issues privately as described in
[SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
