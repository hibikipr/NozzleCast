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
}
