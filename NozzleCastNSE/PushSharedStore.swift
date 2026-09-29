import Foundation

/// Mirrors `NozzleCast/PushSharedStore.swift` — duplicated rather than shared because this
/// extension target can't use the main app target's file-system-synced group membership
/// without hand-editing exception sets into the pbxproj. Keep the App Group id and JSON schema
/// (NtfyConfig, HistoryEntry) identical between the two copies; nothing else here should drift.
enum PushSharedStore {
    static let appGroup = "group.com.victormanuel.NozzleCast"

    private static var containerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)!
    }

    struct NtfyConfig: Codable {
        var server: String
        var topic: String
        var authToken: String?
    }

    private static var ntfyConfigURL: URL { containerURL.appendingPathComponent("ntfy-config.json") }

    static func loadNtfyConfig() -> NtfyConfig? {
        guard let data = try? Data(contentsOf: ntfyConfigURL) else { return nil }
        return try? JSONDecoder().decode(NtfyConfig.self, from: data)
    }

    struct HistoryEntry: Codable, Identifiable {
        var id: String
        var title: String
        var body: String
        var receivedAt: Date
        var isRead: Bool?

        var isUnread: Bool { isRead == false }
    }

    private static var historyURL: URL { containerURL.appendingPathComponent("notification-history.json") }
    private static let historyLimit = 100

    /// Read-modify-write of the history file under an `NSFileCoordinator` write lock. The app
    /// (mark-all-read, clear) and the notification extension (one append per push, possibly
    /// several at once) are separate processes rewriting the same file; uncoordinated, whichever
    /// wrote last silently discarded the other's change — a lost history entry, or a
    /// mark-all-read that didn't stick.
    private static func updateHistory(_ transform: (inout [HistoryEntry]) -> Void) {
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: historyURL, options: .forMerging, error: &coordinationError) { url in
            var entries: [HistoryEntry] = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([HistoryEntry].self, from: $0) } ?? []
            transform(&entries)
            guard let data = try? JSONEncoder().encode(entries) else { return }
            try? data.write(to: url, options: .atomic)
        }
        if let coordinationError {
            NSLog("NCDEBUG notification history coordination failed: %@", coordinationError.localizedDescription)
        }
    }

    static func appendHistory(_ entry: HistoryEntry) {
        var dropped: [HistoryEntry] = []
        updateHistory { entries in
            entries.removeAll { $0.id == entry.id }
            entries.insert(entry, at: 0)
            if entries.count > historyLimit {
                dropped = Array(entries.suffix(entries.count - historyLimit))
                entries.removeLast(dropped.count)
            }
        }
        for old in dropped { deleteHistoryImage(id: old.id) }
    }

    static func loadHistory() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        return (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    static func unreadCount() -> Int {
        loadHistory().filter(\.isUnread).count
    }

    // MARK: - Notification history images (the ntfy attachment photo, kept alongside the entry)

    private static var historyImagesDir: URL {
        let dir = containerURL.appendingPathComponent("notification-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func historyImageURL(id: String) -> URL {
        historyImagesDir.appendingPathComponent("\(id).jpg")
    }

    static func saveHistoryImage(_ data: Data, id: String) {
        try? data.write(to: historyImageURL(id: id), options: .atomic)
    }

    static func deleteHistoryImage(id: String) {
        try? FileManager.default.removeItem(at: historyImageURL(id: id))
    }

    // MARK: - Live Activity preferences (mirrors NozzleCast/PushSharedStore.swift — keep in sync)

    private static var sharedDefaults: UserDefaults { UserDefaults(suiteName: appGroup)! }

    static var liveActivitiesEnabled: Bool {
        get { sharedDefaults.object(forKey: "liveActivitiesEnabled") as? Bool ?? true }
        set { sharedDefaults.set(newValue, forKey: "liveActivitiesEnabled") }
    }

    static var liveActivityCameraPreviewEnabled: Bool {
        get { sharedDefaults.object(forKey: "liveActivityCameraPreviewEnabled") as? Bool ?? true }
        set { sharedDefaults.set(newValue, forKey: "liveActivityCameraPreviewEnabled") }
    }

    /// Whether a `nozzlecast-relay` is configured — mirrored here by the app (`RelayConfigStore`
    /// lives in the app's own container, which the notification extension can't read). With a
    /// relay, it is the Live Activity's only content writer and the extension must leave
    /// activities alone; see `NotificationService.updateLiveActivity`.
    static var relayConfigured: Bool {
        get { sharedDefaults.bool(forKey: "relayConfigured") }
        set { sharedDefaults.set(newValue, forKey: "relayConfigured") }
    }
}
