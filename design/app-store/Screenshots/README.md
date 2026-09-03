# App Store Screenshots

Captured in portrait at Apple's exact required native pixel dimensions, so they
upload to App Store Connect without any scaling.

| Folder | Device class | Size |
|---|---|---|
| `iPhone-6.9/` | iPhone 6.9" (17/16 Pro Max class) | 1320×2868 |
| `iPad-13/` | iPad 13" (Pro M4/M5 class) | 2064×2752 |
| `iPhone-6.5/` | iPhone 6.5" (Xs Max/11 Pro Max class) | 1242×2688 |

Only the 6.9" and 13" sets are required for a universal iPhone+iPad app;
6.5" is optional/legacy but still selectable in App Store Connect, so it's
included too.

Each set covers the same five screens, in order:

1. `01-monitor-home` — the Monitor tab: three printers (Workshop X1C printing
   at 64% with live AMS colors, Garage A1 idle, Office P1S paused), status
   badges, and per-printer progress bars
2. `02-printer-detail-printing` — Workshop X1C's detail screen: job name,
   progress, remaining time, print controls, live nozzle/bed/chamber temps,
   and the AMS filament tray colors
3. `03-inventory` — the Inventory tab's filament grid: all 8 spools with
   material/color/brand, remaining-percent bars, and where each one is
   loaded (AMS slot vs. in storage)
4. `04-settings` — Settings: printer list and the App Icon picker
   (Default/Classic/Snow/Midnight/Ice)
5. `05-printer-detail-paused` — Office P1S's detail screen in the Paused
   state, showing the Resume/Stop controls and a differently-loaded AMS

Content is NozzleCast's own built-in demo data (`MockData.swift` /
`AppStore.loadMockData()`) — the same fallback the app shows to any user who
hasn't yet connected a Bambuddy server. No debug hooks, seeding, or app code
changes were needed to produce it, and it fully round-trips: nothing to
revert.

The `04-settings` shots are cropped: the Push Notifications/Bambuddy Server
rows above "Printers" read "Not imported" / "Not configured" / "Showing demo
data" in this unconfigured demo state, which isn't representative copy for
a store listing screenshot. Cropped out in post (matching background color,
no visible seam) rather than editing the app's real empty-state strings for
a screenshot.

## Capture method

`xcrun simctl io <device> screenshot`, against three purpose-made simulators
(`AppStore-iPhone-6.9` reused from an existing iPhone 17 Pro Max sim,
`AppStore-iPad-13`, `AppStore-iPhone-6.5`) all on the iOS 27.0 runtime (the
app's deployment target exceeded the iOS 26.5 runtime's supported range).
Status bar normalized via `xcrun simctl status_bar override` (9:41, full wifi,
charging battery). Navigation between screens driven via the iOS Simulator
control tool's tap/swipe actions.
