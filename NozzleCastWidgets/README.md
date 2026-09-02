# NozzleCastWidgets (Widget Extension)

Hosts the Live Activity's UI — Dynamic Island (compact, expanded, minimal) and the Lock Screen
card. No home-screen widgets, just the one Live Activity.

## Layout

- **`NozzleCastWidgetsBundle.swift`** — the extension's `@main` entry point.
- **`PrintActivityWidget.swift`** — the actual layout: a thumbnail that prefers the live camera
  snapshot and falls back to the cover render, a progress bar driven by
  `ProgressView(timerInterval:)` so it animates smoothly on-device between refreshes, and a
  percentage `Text` derived from that *same* date interpolation rather than the raw progress
  snapshot — the two used to visibly disagree, since the bar animates continuously while a plain
  percentage only updates when the app (or the notification extension) pushes a new value.
- **`PrintActivityAttributes.swift`** — duplicated from the app target (see `../ARCHITECTURE.md`
  for why); keep in sync by hand if either changes.

Rendered content only — it never starts, updates, or ends an activity itself. That's
`PrintLiveActivityManager` (in the app) and `NotificationService` (in the NSE); see
[`../ARCHITECTURE.md`](../ARCHITECTURE.md#live-activities).
