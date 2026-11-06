import Foundation
import UserNotifications

/// Bambuddy's alerts fetched from the user's relay, for a relay without Apple push keys (relay
/// v1.8.0+, README "Without Apple push keys") — or a device the relay can't push to.
///
/// Bambuddy's Webhook provider still posts each alert to the relay, and the relay still leaves out
/// what this device muted (`RelayAlertClient.syncMutes`), but with nothing to push through it keeps
/// them for the app to fetch (`GET /alerts`). The app checks on every refresh while it's open and on
/// iOS background refresh when it isn't (the same task as `BambuddyAlertFeed`), adds new alerts to
/// the notification history with their photo, and posts them as local notifications. No Firebase
/// config and no Apple push keys needed — but iOS decides when background refresh runs, so an alert
/// can arrive well after it happened while the app isn't open.
enum RelayAlertFeed {
    /// Active when the relay delivers alerts but can't push them here.
    static var isActive: Bool {
        PushSharedStore.relayAlertsActive && (!PushSharedStore.relayAlertsPush || PushSharedStore.deviceToken == nil)
    }

    /// The most recent failure, for Settings.
    private(set) static var lastError: String?
    private(set) static var lastCheckedAt: Date?

    private static var isChecking = false

    /// The most local notifications one check posts; anything beyond is summed up in one more.
    private static let maxNotificationsPerCheck = 5

    /// The relay's highest feed id already handled, per relay. A different relay — or none
    /// recorded yet — starts from its current newest alert instead of replaying old ones.
    private struct Cursor: Codable {
        var relay: String
        var lastID: Int
    }

    private static let cursorKey = "RelayAlertFeed.cursor"

    private static var cursor: Cursor? {
        get { UserDefaults.standard.data(forKey: cursorKey).flatMap { try? JSONDecoder().decode(Cursor.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: cursorKey) }
    }

    /// Fetches the alerts the relay received since the last check, adds them to the notification
    /// history, and posts them as local notifications. Returns how many new alerts there were.
    @discardableResult
    static func check() async -> Int {
        guard isActive, !isChecking, let relay = RelayConfigStore.load()?.url.absoluteString else { return 0 }
        isChecking = true
        defer { isChecking = false }

        let saved = cursor.flatMap { $0.relay == relay ? $0.lastID : nil }
        let feed: RelayAlertClient.Feed
        do {
            feed = try await RelayAlertClient.fetchAlerts(after: saved)
            lastError = nil
            lastCheckedAt = Date()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return 0
        }

        // First check against this relay, or the relay's feed started over (its data was reset):
        // continue from its newest alert.
        guard let saved, feed.latestId >= saved else {
            cursor = Cursor(relay: relay, lastID: feed.latestId)
            return 0
        }
        cursor = Cursor(relay: relay, lastID: max(saved, feed.latestId))

        // The relay already left out this device's mutes; this catches one muted since it last
        // heard from the app.
        let fresh = feed.items
            .filter { $0.id > saved && !PushSharedStore.isMuted(title: $0.title, body: $0.body) }
            .sorted { $0.id < $1.id }
        guard !fresh.isEmpty else { return 0 }

        var photos: [Int: Data] = [:]
        for alert in fresh {
            if let photoID = alert.photoID, let data = await RelayAlertClient.photo(id: photoID) {
                photos[alert.id] = data
                PushSharedStore.saveHistoryImage(data, id: historyID(alert))
            }
            await PushSharedStore.appendHistory(PushSharedStore.HistoryEntry(
                id: historyID(alert),
                title: alert.title,
                body: alert.body,
                receivedAt: parseDate(alert.receivedAt) ?? Date(),
                isRead: false
            ))
        }
        await postNotifications(for: fresh, photos: photos)
        return fresh.count
    }

    private static func historyID(_ alert: RelayAlertClient.FeedItem) -> String {
        "relayfeed-\(alert.id)"
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func postNotifications(for alerts: [RelayAlertClient.FeedItem], photos: [Int: Data]) async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }

        // The newest ones if there are too many: they're the ones still worth acting on.
        let shown = alerts.suffix(maxNotificationsPerCheck)
        for alert in shown {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            content.threadIdentifier = "bambuddy"
            content.interruptionLevel = alert.timeSensitive == true ? .timeSensitive : .active
            if let data = photos[alert.id], let attachment = attachment(data, id: historyID(alert)) {
                content.attachments = [attachment]
            }
            try? await center.add(UNNotificationRequest(identifier: historyID(alert), content: content, trigger: nil))
        }
        let skipped = alerts.count - shown.count
        if skipped > 0 {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "More alerts from your server", comment: "Summary notification when several alerts arrived at once")
            content.body = String(AttributedString(localized: "^[\(skipped) more alert](inflect: true) arrived. Open NozzleCast to see them all.", comment: "Summary notification body").inflected().characters)
            try? await center.add(UNNotificationRequest(identifier: "relayfeed-summary-\(UUID().uuidString)", content: content, trigger: nil))
        }
        try? await center.setBadgeCount(PushSharedStore.unreadCount())
    }

    /// iOS moves an attachment's file into its own store, so each gets a fresh temporary copy.
    private static func attachment(_ data: Data, id: String) -> UNNotificationAttachment? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(id)-\(UUID().uuidString).jpg")
        guard (try? data.write(to: url)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: id, url: url)
    }
}
