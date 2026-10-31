# NozzleCastWidgets (Widget Extension)

Hosts the Live Activity's UI (Dynamic Island + Lock Screen card) and the AMS Colors home-screen
widget.

## Layout

- **`NozzleCastWidgetsBundle.swift`** — the extension's `@main` entry point.
- **`PrintActivityWidget.swift`** — the Live Activity layout: the sliced-plate cover render (never
  the live camera snapshot; the sharp copy the app saved in `LiveActivityCoverStore`, else the
  content-state's small `coverImage`) greyed out and refilled in colour from the bottom up to the
  current layer, a time-remaining countdown (`Text(timerInterval:)`, the one part that ticks on-device
  between pushes; it shows the state label instead while paused or finished), a 20-segment
  progress bar, and percentage/layer counters that roll to each new value. Everything except
  the countdown animates only when a new content state arrives — ActivityKit runs no animation
  between updates.
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
