# NozzleCastWidgets (Widget Extension)

Hosts the Live Activity's UI (Dynamic Island + Lock Screen card) and the AMS Colors home-screen
widget.

## Layout

- **`NozzleCastWidgetsBundle.swift`** — the extension's `@main` entry point.
- **`PrintActivityWidget.swift`** — the Live Activity layout: a thumbnail that prefers the live
  camera snapshot and falls back to the cover render, a progress bar driven by
  `ProgressView(timerInterval:)` so it animates smoothly on-device between refreshes, and a
  percentage `Text` derived from that *same* date interpolation rather than the raw progress
  snapshot — the two used to visibly disagree, since the bar animates continuously while a plain
  percentage only updates when the app (or the notification extension) pushes a new value.
- **`AMSWidget.swift`** — the AMS Colors home-screen widget (Small/Medium/Large). Reads
  `PrinterAMSSnapshot`s the app wrote via `AMSWidgetStore` (app-group `UserDefaults`, see
  `NozzleCastShared/AMSWidgetSnapshot.swift`) rather than hitting the network itself. One AMS
  unit per row (`A1`/`A2`/`HT` tag, slot swatches as its columns), bounded to 3 units / 10 slots
  per printer and 2 printers per family so a growing fleet gets a "+N" chip instead of clipped
  or overflowing content. Filament swatches render through the shared `FilamentSwatchView` with
  `.widgetAccentedRenderingMode(.fullColor)` so color survives iOS's tinted/accented home-screen
  modes. `RefreshAMSIntent` (Large only) reloads the timeline on tap; `AMSWidgetStore.lastSavedAt`
  drives the "Updated Xm ago" staleness stamp everywhere else.
- **`PrintActivityAttributes.swift`** — duplicated from the app target (see `../ARCHITECTURE.md`
  for why); keep in sync by hand if either changes.

The Live Activity views are rendered content only — they never start, update, or end an activity
themselves. That's `PrintLiveActivityManager` (in the app) and `NotificationService` (in the NSE);
see [`../ARCHITECTURE.md`](../ARCHITECTURE.md#live-activities). `AMSWidget` similarly never
fetches data itself — `AppStore.makeAMSSnapshots` (in the app) builds the snapshots and calls
`AMSWidgetStore.save` after every printer/inventory refresh.
