# NozzleCastNSE (Notification Service Extension)

Turns Bambuddy's data-only ntfy push payload into an actual visible notification — there's no
`aps.alert`, so nothing shows up unless this extension builds it.

## Layout

- **`NotificationService.swift`** — the extension itself. Parses the push, downloads and attaches
  the camera photo, appends to the shared notification history, sets the app icon badge, and —
  critically — is the only thing that keeps a printer's Live Activity accurate while the app is
  backgrounded: it pushes the live snapshot thumbnail into the matching activity on every
  photo-bearing event, and detects Bambuddy's completion/failure/stop events to finalize (and end)
  the activity itself.
- **`NtfyPushMessage.swift`** — parses both shapes ntfy's messages arrive in: the flat push
  payload (`userInfo` dict from the notification) and the nested REST JSON used for the
  `poll_request` fallback.
- **`PushSharedStore.swift`, `PrintActivityAttributes.swift`** — duplicated from the app target
  (see `../ARCHITECTURE.md` for why); keep these in sync by hand if either changes.

Runs as its own process, separate from the main app — see
[`../ARCHITECTURE.md`](../ARCHITECTURE.md#live-activities) for the concurrency bugs that came from
treating it like it wasn't (un-awaited `Task { }` calls that silently never completed).
