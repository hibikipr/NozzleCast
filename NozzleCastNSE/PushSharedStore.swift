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

    static func appendHistory(_ entry: HistoryEntry) {
        var entries = loadHistory()
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        let dropped = entries.count > historyLimit ? entries.suffix(entries.count - historyLimit) : []
        if !dropped.isEmpty { entries.removeLast(dropped.count) }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: historyURL, options: .atomic)
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
}
