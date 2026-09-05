import Foundation

/// Everything shared between the main app and the NotificationService extension, which runs as
/// a separate process and can't see the main app's Keychain or UserDefaults. Kept in the App
/// Group container instead — a plain JSON file rather than Core Data, since our needs are much
/// smaller than a full multi-subscription client's: exactly one ntfy topic (Bambuddy's alerts),
/// and a short local notification history for the in-app list.
enum PushSharedStore {
    static let appGroup = "group.com.victormanuel.NozzleCast"

    private static var containerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)!
    }

    // MARK: - ntfy topic config (needed by the NSE for the poll_request fallback fetch)

    struct NtfyConfig: Codable {
        var server: String
        var topic: String
        var authToken: String?
    }

    private static var ntfyConfigURL: URL { containerURL.appendingPathComponent("ntfy-config.json") }

    static func saveNtfyConfig(_ config: NtfyConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: ntfyConfigURL, options: .atomic)
    }

    static func loadNtfyConfig() -> NtfyConfig? {
        guard let data = try? Data(contentsOf: ntfyConfigURL) else { return nil }
        return try? JSONDecoder().decode(NtfyConfig.self, from: data)
    }

    static func clearNtfyConfig() {
        try? FileManager.default.removeItem(at: ntfyConfigURL)
    }

    // MARK: - Notification history (written by the NSE, read by the main app)

    struct HistoryEntry: Codable, Identifiable {
        var id: String
        var title: String
        var body: String
        var receivedAt: Date
        /// Optional (not `Bool` with a default) so entries logged before this field existed
        /// still decode — a missing key on a non-optional property throws in synthesized
        /// `Decodable`, which would silently blank out the whole history. `nil` reads as "seen
        /// before this feature existed," not as unread.
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

    static func clearHistory() {
        try? FileManager.default.removeItem(at: historyURL)
        try? FileManager.default.removeItem(at: historyImagesDir)
    }

    static func unreadCount() -> Int {
        loadHistory().filter(\.isUnread).count
    }

    static func markAllRead() {
        var entries = loadHistory()
        guard entries.contains(where: \.isUnread) else { return }
        for i in entries.indices { entries[i].isRead = true }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: historyURL, options: .atomic)
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

    static func loadHistoryImage(id: String) -> Data? {
        try? Data(contentsOf: historyImageURL(id: id))
    }

    static func deleteHistoryImage(id: String) {
        try? FileManager.default.removeItem(at: historyImageURL(id: id))
    }
}
