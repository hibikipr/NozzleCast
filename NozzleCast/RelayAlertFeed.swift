import Foundation
import ImageIO
import UniformTypeIdentifiers
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
    private static let maxConcurrentPhotoDownloads = 4
    private static let photoFetchTimeout: Duration = .seconds(12)

    private static let iso8601FractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let iso8601WholeStyle = Date.ISO8601FormatStyle()

    private nonisolated enum PhotoFetchEvent: Sendable {
        case photo(alertID: Int, data: Data?)
        case timedOut
    }

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
        // Saved only once these are handled: a check cut short (a background wake running out of
        // time while fetching photos) fetches them again next time instead of skipping them.
        // History and notifications are keyed by the alert's id, so a repeat replaces, not adds.
        let advanced = Cursor(relay: relay, lastID: max(saved, feed.latestId))

        // The relay already left out this device's mutes; this catches one muted since it last
        // heard from the app.
        let fresh = feed.items
            .filter { $0.id > saved && !PushSharedStore.isMuted(title: $0.title, body: $0.body) }
            .sorted { $0.id < $1.id }
        guard !fresh.isEmpty else {
            cursor = advanced
            return 0
        }

        let photos = await fetchPhotos(for: fresh)
        for alert in fresh {
            if let data = photos[alert.id] {
                PushSharedStore.saveHistoryImage(data, id: historyID(alert))
            }
        }
        let historyEntries = fresh.map { alert in
            PushSharedStore.HistoryEntry(
                id: historyID(alert),
                title: alert.title,
                body: alert.body,
                receivedAt: parseDate(alert.receivedAt) ?? Date(),
                isRead: false
            )
        }
        await PushSharedStore.appendHistory(historyEntries)
        await postNotifications(for: fresh, photos: photos)
        cursor = advanced
        return fresh.count
    }

    private static func fetchPhotos(for alerts: [RelayAlertClient.FeedItem]) async -> [Int: Data] {
        let targets = alerts.compactMap { alert in
            alert.photoID.map { (id: alert.id, photoID: $0) }
        }
        guard !targets.isEmpty else { return [:] }

        return await withTaskGroup(of: PhotoFetchEvent.self) { group in
            group.addTask {
                try? await Task.sleep(for: photoFetchTimeout)
                return .timedOut
            }

            var nextIndex = 0
            func enqueueNext() {
                guard nextIndex < targets.count else { return }
                let target = targets[nextIndex]
                nextIndex += 1
                group.addTask {
                    let data = await RelayAlertClient.photo(id: target.photoID)
                    return .photo(alertID: target.id, data: data)
                }
            }

            for _ in 0..<min(maxConcurrentPhotoDownloads, targets.count) {
                enqueueNext()
            }

            var photos: [Int: Data] = [:]
            var remaining = targets.count
            while remaining > 0, let event = await group.next() {
                switch event {
                case .photo(let alertID, let data):
                    remaining -= 1
                    if let data {
                        photos[alertID] = data
                    }
                    enqueueNext()
                case .timedOut:
                    group.cancelAll()
                    return photos
                }
            }
            group.cancelAll()
            return photos
        }
    }

    private static func historyID(_ alert: RelayAlertClient.FeedItem) -> String {
        "relayfeed-\(alert.id)"
    }

    private static func parseDate(_ value: String) -> Date? {
        (try? iso8601FractionalStyle.parse(value)) ?? (try? iso8601WholeStyle.parse(value))
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
        let ext = imageFileExtension(for: data)
        let safeStem = String(PushSharedStore.sanitizedImageFilename(for: id).dropLast(4))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeStem)-\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: url)
            return try UNNotificationAttachment(identifier: id, url: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    private static func imageFileExtension(for data: Data) -> String {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let uti = CGImageSourceGetType(source) as String? {
            switch uti {
            case UTType.jpeg.identifier: return "jpg"
            case UTType.png.identifier: return "png"
            case UTType.webP.identifier: return "webp"
            case UTType.heic.identifier, UTType.heif.identifier: return "heic"
            case UTType.gif.identifier: return "gif"
            default:
                if let ext = UTType(uti)?.preferredFilenameExtension {
                    return ext
                }
            }
        }
        return "jpg"
    }
}
