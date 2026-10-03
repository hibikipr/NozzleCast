import BackgroundTasks
import Foundation
import UserNotifications

/// Bambuddy's alerts for installs with no Firebase config, read from its notification log.
///
/// With Firebase, alerts arrive as pushes: Bambuddy publishes to ntfy, ntfy relays through the
/// user's Firebase project, and the notification extension shows them. Without it nothing pushes
/// to this device at all. But Bambuddy logs every alert it sends, to every provider it has —
/// ntfy, Pushover, Discord, email and the rest — and serves that log over its API. So the app
/// reads the log instead: on every refresh while it's open (including the relay's background
/// wakes), and on iOS background refresh when it isn't. New entries go into the same in-app
/// history the extension writes to, and are posted as local notifications.
///
/// This is a fallback, not push: iOS decides when background refresh runs (often every half hour
/// or longer, less on a phone that's rarely used), so an alert can arrive well after it happened.
enum BambuddyAlertFeed {
    /// Active whenever there's no Firebase config to push alerts through.
    static var isActive: Bool { !FirebaseConfigStore.isConfigured }

    /// The most recent failure, for Settings — a key without `notifications:read` gets a 403 on
    /// every check, which otherwise looks exactly like "no alerts".
    private(set) static var lastError: String?
    private(set) static var lastCheckedAt: Date?

    private static var isChecking = false

    /// The background app refresh task that checks the log while the app isn't running. Listed
    /// in Info.plist's `BGTaskSchedulerPermittedIdentifiers`.
    static let backgroundTaskIdentifier = "com.victormanuel.NozzleCast.bambuddy-alerts"

    /// Asks iOS for the next background check. iOS treats the date as "not before" and picks
    /// the actual time itself; asking again replaces the pending request.
    static func scheduleBackgroundCheck() {
        guard isActive else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backgroundTaskIdentifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NSLog("NCDEBUG alert feed: couldn't schedule background check: %@", String(describing: error))
        }
    }

    /// Rows fetched per check. Generous for one interval between checks; if more arrive than
    /// this, the oldest of them are skipped rather than paged in.
    private static let pageSize = 30
    /// The most local notifications one check posts; anything beyond is summed up in one more.
    private static let maxNotificationsPerCheck = 5

    /// Highest log id already handled, per server. A different server — or none recorded yet —
    /// starts from its current newest entry instead of announcing a week of old alerts.
    private struct Cursor: Codable {
        var server: String
        var lastLogID: Int
    }

    private static let cursorKey = "BambuddyAlertFeed.cursor"

    private static var cursor: Cursor? {
        get { UserDefaults.standard.data(forKey: cursorKey).flatMap { try? JSONDecoder().decode(Cursor.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: cursorKey) }
    }

    /// Fetches what Bambuddy logged since the last check, adds it to the notification history,
    /// and posts it as local notifications. Returns how many new alerts there were.
    @discardableResult
    static func check(using client: BambuddyAPIClient) async -> Int {
        guard isActive, !isChecking else { return 0 }
        isChecking = true
        defer { isChecking = false }

        let entries: [BambuddyNotificationLogDTO]
        do {
            entries = try await client.notificationLog(limit: pageSize)
            lastError = nil
            lastCheckedAt = Date()
        } catch BambuddyAPIError.http(403, _) {
            lastError = String(localized: "Your API key can't read Bambuddy's notifications. Give it the notifications:read permission.", comment: "Alert feed error: API key lacks permission")
            return 0
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return 0
        }

        let server = client.baseURL.absoluteString
        let newestID = entries.map(\.id).max() ?? 0

        guard let cursor, cursor.server == server else {
            // First check against this server: what's already in the log is history, not news.
            // It still fills the in-app list (already read), so it isn't empty on day one.
            for alert in deduplicated(entries).prefix(20).reversed() {
                await PushSharedStore.appendHistory(historyEntry(for: alert, isRead: true))
            }
            Self.cursor = Cursor(server: server, lastLogID: newestID)
            return 0
        }

        // Oldest first, so the history and the notifications come out in the order they happened.
        let fresh = Array(deduplicated(entries.filter { $0.id > cursor.lastLogID }).reversed())
        guard !fresh.isEmpty else { return 0 }
        Self.cursor = Cursor(server: server, lastLogID: max(cursor.lastLogID, newestID))

        for alert in fresh {
            await PushSharedStore.appendHistory(historyEntry(for: alert, isRead: false))
        }
        await postNotifications(for: fresh)
        return fresh.count
    }

    /// One alert sent to two providers is two log rows a moment apart — keep one of each.
    /// Returns newest first.
    private static func deduplicated(_ entries: [BambuddyNotificationLogDTO]) -> [BambuddyNotificationLogDTO] {
        var kept: [BambuddyNotificationLogDTO] = []
        for entry in entries.sorted(by: { $0.id > $1.id }) {
            let date = AppStore.parseBambuddyTimestamp(entry.createdAt) ?? .distantPast
            let isDuplicate = kept.contains { other in
                guard other.title == entry.title, other.message == entry.message, other.printerId == entry.printerId else { return false }
                let otherDate = AppStore.parseBambuddyTimestamp(other.createdAt) ?? .distantPast
                return abs(otherDate.timeIntervalSince(date)) < 60
            }
            if !isDuplicate { kept.append(entry) }
        }
        return kept
    }

    private static func historyEntry(for alert: BambuddyNotificationLogDTO, isRead: Bool) -> PushSharedStore.HistoryEntry {
        PushSharedStore.HistoryEntry(
            id: "bblog-\(alert.id)",
            title: alert.title,
            body: alert.message,
            receivedAt: AppStore.parseBambuddyTimestamp(alert.createdAt) ?? Date(),
            isRead: isRead
        )
    }

    private static func postNotifications(for alerts: [BambuddyNotificationLogDTO]) async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }

        // The newest ones if there are too many: they're the ones still worth acting on.
        let shown = alerts.suffix(maxNotificationsPerCheck)
        for alert in shown {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.message
            content.sound = .default
            if let printerName = alert.printerName { content.threadIdentifier = printerName }
            try? await center.add(UNNotificationRequest(identifier: "bblog-\(alert.id)", content: content, trigger: nil))
        }
        let skipped = alerts.count - shown.count
        if skipped > 0 {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "More alerts from Bambuddy", comment: "Summary notification when several alerts arrived at once")
            content.body = String(AttributedString(localized: "^[\(skipped) more alert](inflect: true) arrived. Open NozzleCast to see them all.", comment: "Summary notification body").inflected().characters)
            try? await center.add(UNNotificationRequest(identifier: "bblog-summary-\(UUID().uuidString)", content: content, trigger: nil))
        }
        try? await center.setBadgeCount(PushSharedStore.unreadCount())
    }
}
