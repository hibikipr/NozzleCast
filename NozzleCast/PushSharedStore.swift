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
    }

    private static var historyURL: URL { containerURL.appendingPathComponent("notification-history.json") }
    private static let historyLimit = 100

    static func appendHistory(_ entry: HistoryEntry) {
        var entries = loadHistory()
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        if entries.count > historyLimit { entries.removeLast(entries.count - historyLimit) }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }

    static func loadHistory() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        return (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    static func clearHistory() {
        try? FileManager.default.removeItem(at: historyURL)
    }
}
