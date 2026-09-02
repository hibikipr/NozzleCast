# NozzleCast (app target)

The main app: all UI, the Bambuddy API client, and the managers that drive the notification and
widget extensions.

## Layout

- **`MyApp.swift`, `AppDelegate.swift`, `RootView.swift`** — app entry point, APNs/UNUserNotification
  delegate wiring, and the root tab view.
- **`AppStore.swift`** — the single `@Observable` source of truth (printers, spools, connection
  state); everything else reads from it via `@Environment(AppStore.self)`.
- **`BambuddyAPIClient.swift`, `BambuddyConfig.swift`** — the REST client and its Keychain-backed
  server URL/API key.
- **`Models.swift`, `DesignSystem.swift`, `Components.swift`** — domain types and shared UI.
- **`MonitorView.swift`, `PrinterDetailView.swift`, `InventoryView.swift`, `ScanView.swift`,
  `SettingsView.swift`** — the four tabs (Monitor pushes to Printer Detail) plus their sheets
  (`AMSAssignSheet`, `AssignPickerSheet`, `EditSpoolSheet`, `AIDetectionSheet`,
  `HMSWarningsSheet`, `BambuddyConnectionSheet`).
- **`FilamentLookupService.swift`, `OFDClient.swift`, `SpoolmanDBCommunityClient.swift`,
  `FilamentCode.swift`, `FilamentTitleParser.swift`, `HMSCodeLookup.swift`,
  `DataScannerView.swift`** — the Scan tab's barcode/label lookup pipeline and HMS error code
  resolution.
- **`PushNotificationManager.swift`, `FirebaseConfigStore.swift`, `PushTopicHash.swift`,
  `PushSharedStore.swift`, `NotificationsView.swift`** — the push pipeline's app-side half: Firebase
  setup, topic subscription, and the in-app notification history UI.
- **`PrintLiveActivityManager.swift`, `PrintActivityAttributes.swift`** — starts/updates/ends the
  Live Activity per printing printer from `AppStore.refresh()`.

See [`../ARCHITECTURE.md`](../ARCHITECTURE.md) for why these are built the way they are, not just
what they do.
