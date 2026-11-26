import os
import CryptoKit
import Foundation
import Security

/// Mirrors `NozzleCast/PushSharedStore.swift` — duplicated rather than shared because this
/// extension target can't use the main app target's file-system-synced group membership
/// without hand-editing exception sets into the pbxproj. Keep the App Group id, shared Keychain
/// service/keys/access group, and JSON schemas identical between the two copies; nothing else
/// here should drift.
enum PushSharedStore {
    static let appGroup = "group.com.victormanuel.NozzleCast"
    private static let ntfyKeychainKey = "ntfy-config"
    private static let relayConnectionKeychainKey = "relay-connection"

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    private enum SharedKeychain {
        private static let service = "com.victormanuel.NozzleCast"
        private static let sharedAccessGroupSuffix = "com.victormanuel.NozzleCast.shared"

        static var sharedAccessGroup: String? {
            guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
                  !prefix.isEmpty,
                  !prefix.contains("$(")
            else { return nil }
            return prefix + sharedAccessGroupSuffix
        }

        enum ReadResult {
            case found(String)
            case notFound
            case unavailable(OSStatus)
        }

        static func read(_ key: String, accessGroup: String? = sharedAccessGroup) -> ReadResult {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            if let accessGroup {
                query[kSecAttrAccessGroup as String] = accessGroup
            }
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
                    return .unavailable(status)
                }
                return .found(string)
            case errSecItemNotFound:
                return .notFound
            case errSecMissingEntitlement where accessGroup != nil:
                NSELog.push.debug("NSE keychain read for '\(key, privacy: .private)' missing entitlement for access group '\(accessGroup ?? "", privacy: .private)', falling back to default group")
                return read(key, accessGroup: nil)
            default:
                NSELog.push.debug("NSE keychain read for '\(key, privacy: .private)' unavailable (OSStatus \(status, privacy: .public))")
                return .unavailable(status)
            }
        }

        @discardableResult
        static func set(_ value: String, forKey key: String, accessGroup: String? = sharedAccessGroup) -> Bool {
            let data = Data(value.utf8)
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
            ]
            if let accessGroup {
                query[kSecAttrAccessGroup as String] = accessGroup
            }
            var status = SecItemUpdate(
                query as CFDictionary,
                [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                ] as CFDictionary
            )
            if status == errSecItemNotFound {
                var attributes = query
                attributes[kSecValueData as String] = data
                attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                status = SecItemAdd(attributes as CFDictionary, nil)
            }
            if status == errSecMissingEntitlement, accessGroup != nil {
                NSELog.push.debug("NSE keychain write for '\(key, privacy: .private)' missing entitlement for access group '\(accessGroup ?? "", privacy: .private)', falling back to default group")
                return set(value, forKey: key, accessGroup: nil)
            }
            return status == errSecSuccess
        }
    }

    struct NtfyConfig: Codable, Equatable, Sendable {
        var server: String
        var topic: String
        var authToken: String?
    }

    private static var ntfyConfigURL: URL? { containerURL?.appendingPathComponent("ntfy-config.json") }

    static func loadNtfyConfig() -> NtfyConfig? {
        switch SharedKeychain.read(ntfyKeychainKey) {
        case .found(let json):
            return try? JSONDecoder().decode(NtfyConfig.self, from: Data(json.utf8))
        case .unavailable:
            return nil
        case .notFound:
            guard let url = ntfyConfigURL,
                  FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let config = try? JSONDecoder().decode(NtfyConfig.self, from: data)
            else { return nil }

            if let encoded = try? JSONEncoder().encode(config),
               let json = String(data: encoded, encoding: .utf8),
               SharedKeychain.set(json, forKey: ntfyKeychainKey) {
                try? FileManager.default.removeItem(at: url)
            }
            return config
        }
    }

    struct HistoryEntry: Codable, Identifiable, Sendable {
        var id: String
        var title: String
        var body: String
        var receivedAt: Date
        var isRead: Bool?

        var isUnread: Bool { isRead == false }
    }

    private static var historyURL: URL? { containerURL?.appendingPathComponent("notification-history.json") }
    private static let historyLimit = 100
    private static let historyQueue = DispatchQueue(label: "com.victormanuel.NozzleCast.nse.history")

    private struct HistoryUpdateOutcome<Result: Sendable>: Sendable {
        var dropped: [HistoryEntry]
        var result: Result
    }

    /// Read-modify-write of the history file under an `NSFileCoordinator` write lock, dispatched
    /// onto a dedicated serial queue via `withCheckedContinuation` so the NSE never blocks
    /// Swift's finite cooperative thread pool.
    @discardableResult
    private static func updateHistory<Result: Sendable>(
        _ transform: @escaping @Sendable (inout [HistoryEntry]) -> (dropped: [HistoryEntry], result: Result)
    ) async -> HistoryUpdateOutcome<Result>? {
        guard let url = historyURL else { return nil }
        return await withCheckedContinuation { continuation in
            historyQueue.async {
                var coordinationError: NSError?
                var outcome: HistoryUpdateOutcome<Result>?
                NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { coordinatedURL in
                    var entries: [HistoryEntry] = []
                    if let existing = try? Data(contentsOf: coordinatedURL) {
                        do {
                            entries = try JSONDecoder().decode([HistoryEntry].self, from: existing)
                        } catch {
                            // Starting over overwrites it; keep the unreadable file aside rather than lose it.
                            NSELog.push.error("notification history unreadable, set aside: \(String(describing: error), privacy: .private)")
                            try? existing.write(to: coordinatedURL.deletingLastPathComponent().appendingPathComponent("notification-history.unreadable.json"), options: .atomic)
                        }
                    }
                    let (dropped, result) = transform(&entries)
                    outcome = HistoryUpdateOutcome(dropped: dropped, result: result)
                    guard let data = try? JSONEncoder().encode(entries) else { return }
                    try? data.write(to: coordinatedURL, options: .atomic)
                }
                if let coordinationError {
                    NSELog.push.error("notification history coordination failed: \(coordinationError.localizedDescription, privacy: .private)")
                }
                continuation.resume(returning: outcome)
            }
        }
    }

    @discardableResult
    static func appendHistory(_ newEntries: [HistoryEntry]) async -> Int {
        guard !newEntries.isEmpty else { return unreadCount() }
        let outcome = await updateHistory { entries in
            var seen: Set<String> = []
            var uniqueIncomingReversed: [HistoryEntry] = []
            for entry in newEntries.reversed() {
                if seen.insert(entry.id).inserted {
                    uniqueIncomingReversed.append(entry)
                }
            }
            entries.removeAll { seen.contains($0.id) }
            entries.insert(contentsOf: uniqueIncomingReversed, at: 0)

            var dropped: [HistoryEntry] = []
            if entries.count > historyLimit {
                dropped = Array(entries.suffix(entries.count - historyLimit))
                entries.removeLast(dropped.count)
            }
            return (dropped, entries.filter(\.isUnread).count)
        }
        if let outcome {
            for old in outcome.dropped { deleteHistoryImage(id: old.id) }
            return outcome.result
        }
        return unreadCount()
    }

    @discardableResult
    static func appendHistory(_ entry: HistoryEntry) async -> Int {
        await appendHistory([entry])
    }

    static func loadHistory() -> [HistoryEntry] {
        guard let url = historyURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    static func unreadCount() -> Int {
        loadHistory().filter(\.isUnread).count
    }

    // MARK: - Notification history images (the ntfy attachment photo, kept alongside the entry)

    private static var historyImagesDir: URL? {
        containerURL?.appendingPathComponent("notification-images", isDirectory: true)
    }

    /// Produces a safe filename inside `notification-images/` so untrusted notification/alert IDs
    /// cannot traverse out of the directory (e.g. `../`). Safe `[A-Za-z0-9_-]` IDs up to 128 bytes
    /// keep their `<id>.jpg` name; anything else is hashed with SHA-256.
    static func sanitizedImageFilename(for id: String) -> String {
        let isSafe = !id.isEmpty
            && id.utf8.count <= 128
            && id.utf8.allSatisfy { byte in
                (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                    || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                    || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                    || byte == UInt8(ascii: "_")
                    || byte == UInt8(ascii: "-")
            }
        if isSafe {
            return "\(id).jpg"
        }
        let digest = SHA256.hash(data: Data(id.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hex).jpg"
    }

    private static func historyImageURL(id: String) -> URL? {
        historyImagesDir?.appendingPathComponent(sanitizedImageFilename(for: id), isDirectory: false)
    }

    static func saveHistoryImage(_ data: Data, id: String) {
        guard let imagesDir = historyImagesDir else { return }
        let filename = sanitizedImageFilename(for: id)
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: imagesDir, options: .forMerging, error: &coordinationError) { dirURL in
            try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            let fileURL = dirURL.appendingPathComponent(filename, isDirectory: false)
            try? data.write(to: fileURL, options: .atomic)
        }
        if let coordinationError {
            NSELog.push.error("notification image save coordination failed: \(coordinationError.localizedDescription, privacy: .private)")
        }
    }

    static func deleteHistoryImage(id: String) {
        guard let url = historyImageURL(id: id),
              FileManager.default.fileExists(atPath: url.path)
        else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Live Activity preferences (mirrors NozzleCast/PushSharedStore.swift — keep in sync)

    private static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static var liveActivitiesEnabled: Bool {
        get { sharedDefaults?.object(forKey: "liveActivitiesEnabled") as? Bool ?? true }
        set { sharedDefaults?.set(newValue, forKey: "liveActivitiesEnabled") }
    }

    /// Whether a `nozzlecast-relay` is configured — mirrored here by the app so the notification
    /// extension knows not to compete with the relay for Live Activity updates; see
    /// `NotificationService.updateLiveActivity`.
    static var relayConfigured: Bool {
        get { sharedDefaults?.bool(forKey: "relayConfigured") ?? false }
        set { sharedDefaults?.set(newValue, forKey: "relayConfigured") }
    }

    // MARK: - Alerts through the relay

    /// Whether Bambuddy's alerts come through the relay (its webhook has reached it, see
    /// `RelayAlertClient`): then the app has switched off its ntfy/Firebase path and the alert-log
    /// fallback, and the extension handles the relay's pushes. Set by the app.
    static var relayAlertsActive: Bool {
        get { sharedDefaults?.bool(forKey: "relayAlertsActive") ?? false }
        set { sharedDefaults?.set(newValue, forKey: "relayAlertsActive") }
    }

    /// The relay's address and secret, stored in the shared Keychain Access Group so the
    /// extension can fetch a relay alert's photo.
    struct RelayConnection: Codable, Equatable, Sendable {
        var url: URL
        var authSecret: String
    }

    private static var relayConnectionURL: URL? { containerURL?.appendingPathComponent("relay-connection.json") }

    static func loadRelayConnection() -> RelayConnection? {
        switch SharedKeychain.read(relayConnectionKeychainKey) {
        case .found(let json):
            return try? JSONDecoder().decode(RelayConnection.self, from: Data(json.utf8))
        case .unavailable:
            return nil
        case .notFound:
            guard let url = relayConnectionURL,
                  FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let connection = try? JSONDecoder().decode(RelayConnection.self, from: data)
            else { return nil }

            if let encoded = try? JSONEncoder().encode(connection),
               let json = String(data: encoded, encoding: .utf8),
               SharedKeychain.set(json, forKey: relayConnectionKeychainKey) {
                try? FileManager.default.removeItem(at: url)
            }
            return connection
        }
    }

    // MARK: - Muted alerts (muted in the app's Notifications list)

    /// An alert the user muted, by its exact title and body. Same key and schema as the app's copy.
    struct MutedAlert: Codable, Hashable, Sendable {
        var title: String
        var body: String
    }

    static var mutedAlerts: [MutedAlert] {
        sharedDefaults?.data(forKey: "mutedAlerts").flatMap { try? JSONDecoder().decode([MutedAlert].self, from: $0) } ?? []
    }

    static func isMuted(title: String, body: String) -> Bool {
        mutedAlerts.contains(MutedAlert(title: title, body: body))
    }
}
