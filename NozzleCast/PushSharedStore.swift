import os
import CryptoKit
import Foundation

/// Everything shared between the main app and the NotificationService extension, which runs as
/// a separate process. Non-secret shared state (notification history, images, display prefs) lives
/// in the App Group container; ntfy and relay credentials (`NtfyConfig`, `RelayConnection`) live in
/// the shared Keychain Access Group (`KeychainStore.sharedAccessGroup`,
/// `kSecAttrAccessibleAfterFirstUnlock`) with one-time migration from legacy App Group JSON files.
nonisolated enum PushSharedStore {
    static let appGroup = "group.com.victormanuel.NozzleCast"
    private static let ntfyKeychainKey = "ntfy-config"
    private static let relayConnectionKeychainKey = "relay-connection"

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    private enum SharedStoreError: LocalizedError {
        case relayKeychainWriteFailed

        var errorDescription: String? {
            String(localized: "Couldn't save the relay connection to the shared Keychain.")
        }
    }

    // MARK: - ntfy topic config (needed by the NSE for the poll_request fallback fetch)

    struct NtfyConfig: Codable, Equatable, Sendable {
        var server: String
        var topic: String
        var authToken: String?
    }

    private static var ntfyConfigURL: URL? { containerURL?.appendingPathComponent("ntfy-config.json") }

    static func saveNtfyConfig(_ config: NtfyConfig) {
        if case .found(let existingJSON) = KeychainStore.read(
            ntfyKeychainKey,
            service: KeychainStore.sharedService,
            accessGroup: KeychainStore.sharedAccessGroup
        ),
           let existing = try? JSONDecoder().decode(NtfyConfig.self, from: Data(existingJSON.utf8)),
           existing == config {
            if let url = ntfyConfigURL, FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            return
        }

        guard let data = try? JSONEncoder().encode(config),
              let json = String(data: data, encoding: .utf8),
              KeychainStore.set(
                  json,
                  forKey: ntfyKeychainKey,
                  service: KeychainStore.sharedService,
                  accessGroup: KeychainStore.sharedAccessGroup
              )
        else { return }

        if let url = ntfyConfigURL, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func loadNtfyConfig() -> NtfyConfig? {
        switch KeychainStore.read(
            ntfyKeychainKey,
            service: KeychainStore.sharedService,
            accessGroup: KeychainStore.sharedAccessGroup
        ) {
        case .found(let json):
            return try? JSONDecoder().decode(NtfyConfig.self, from: Data(json.utf8))
        case .unavailable:
            // Do not treat locked Keychain as absent or delete any legacy file.
            return nil
        case .notFound:
            guard let url = ntfyConfigURL,
                  FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let config = try? JSONDecoder().decode(NtfyConfig.self, from: data)
            else { return nil }

            if let encoded = try? JSONEncoder().encode(config),
               let json = String(data: encoded, encoding: .utf8),
               KeychainStore.set(
                   json,
                   forKey: ntfyKeychainKey,
                   service: KeychainStore.sharedService,
                   accessGroup: KeychainStore.sharedAccessGroup
               ) {
                try? FileManager.default.removeItem(at: url)
            }
            return config
        }
    }

    static func clearNtfyConfig() {
        KeychainStore.remove(
            ntfyKeychainKey,
            service: KeychainStore.sharedService,
            accessGroup: KeychainStore.sharedAccessGroup
        )
        if let url = ntfyConfigURL, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Notification history (written by the NSE, read by the main app)

    struct HistoryEntry: Codable, Identifiable, Sendable {
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

    private static var historyURL: URL? { containerURL?.appendingPathComponent("notification-history.json") }
    private static let historyLimit = 100
    private static let historyQueue = DispatchQueue(label: "com.victormanuel.NozzleCast.history")

    private struct HistoryUpdateOutcome<Result: Sendable>: Sendable {
        var dropped: [HistoryEntry]
        var result: Result
    }

    /// Read-modify-write of the history file under an `NSFileCoordinator` write lock, dispatched
    /// onto a dedicated serial queue via `withCheckedContinuation` so `coordinate(writingItemAt:...)`
    /// never blocks the main thread or Swift's finite cooperative thread pool.
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
                            AppLog.storage.error("notification history unreadable, set aside: \(String(describing: error), privacy: .private)")
                            try? existing.write(to: coordinatedURL.deletingLastPathComponent().appendingPathComponent("notification-history.unreadable.json"), options: .atomic)
                        }
                    }
                    let (dropped, result) = transform(&entries)
                    outcome = HistoryUpdateOutcome(dropped: dropped, result: result)
                    guard let data = try? JSONEncoder().encode(entries) else { return }
                    try? data.write(to: coordinatedURL, options: .atomic)
                }
                if let coordinationError {
                    AppLog.storage.error("notification history coordination failed: \(coordinationError.localizedDescription, privacy: .private)")
                }
                continuation.resume(returning: outcome)
            }
        }
    }

    /// Appends a batch of history entries in one coordinated write and returns the updated unread count.
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

    static func clearHistory() async {
        guard let historyURL else { return }
        let imagesDir = historyImagesDir
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            historyQueue.async {
                var coordinationError: NSError?
                let coordinator = NSFileCoordinator()
                if let imagesDir {
                    coordinator.coordinate(
                        writingItemAt: historyURL,
                        options: .forMerging,
                        writingItemAt: imagesDir,
                        options: .forDeleting,
                        error: &coordinationError
                    ) { coordinatedHistoryURL, coordinatedImagesDir in
                        if let data = try? JSONEncoder().encode([HistoryEntry]()) {
                            try? data.write(to: coordinatedHistoryURL, options: .atomic)
                        }
                        if FileManager.default.fileExists(atPath: coordinatedImagesDir.path) {
                            try? FileManager.default.removeItem(at: coordinatedImagesDir)
                        }
                    }
                } else {
                    coordinator.coordinate(writingItemAt: historyURL, options: .forMerging, error: &coordinationError) { coordinatedHistoryURL in
                        if let data = try? JSONEncoder().encode([HistoryEntry]()) {
                            try? data.write(to: coordinatedHistoryURL, options: .atomic)
                        }
                    }
                }
                if let coordinationError {
                    AppLog.storage.error("notification history clear coordination failed: \(coordinationError.localizedDescription, privacy: .private)")
                }
                continuation.resume()
            }
        }
    }

    static func unreadCount() -> Int {
        loadHistory().filter(\.isUnread).count
    }

    static func markAllRead() async {
        guard loadHistory().contains(where: \.isUnread) else { return }
        _ = await updateHistory { entries in
            for i in entries.indices { entries[i].isRead = true }
            return ([], ())
        }
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
            AppLog.storage.error("notification image save coordination failed: \(coordinationError.localizedDescription, privacy: .private)")
        }
    }

    static func loadHistoryImage(id: String) -> Data? {
        guard let url = historyImageURL(id: id) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func deleteHistoryImage(id: String) {
        guard let url = historyImageURL(id: id),
              FileManager.default.fileExists(atPath: url.path)
        else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Live Activity preferences (read by both the main app and the NSE, which can also
    // start/update/end activities on its own from a push — see NotificationService.swift)

    private static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    /// Master on/off switch exposed in Settings, per Apple's Live Activity guidance: "make it
    /// easy for people to turn them off in your app" rather than only via the system Settings
    /// app. Defaults to on since that's the existing behavior for everyone before this setting
    /// existed.
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
    /// notification extension can fetch a relay alert's photo.
    struct RelayConnection: Codable, Equatable, Sendable {
        var url: URL
        var authSecret: String
    }

    private static var relayConnectionURL: URL? { containerURL?.appendingPathComponent("relay-connection.json") }

    static func loadRelayConnection() -> RelayConnection? {
        switch KeychainStore.read(
            relayConnectionKeychainKey,
            service: KeychainStore.sharedService,
            accessGroup: KeychainStore.sharedAccessGroup
        ) {
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
               KeychainStore.set(
                   json,
                   forKey: relayConnectionKeychainKey,
                   service: KeychainStore.sharedService,
                   accessGroup: KeychainStore.sharedAccessGroup
               ) {
                try? FileManager.default.removeItem(at: url)
            }
            return connection
        }
    }

    /// Throws when it can't be written: the notification extension then has no relay address
    /// for alert photos, which the person saving it should hear about.
    static func saveRelayConnection(_ connection: RelayConnection?) throws {
        guard let connection else {
            if case .notFound = KeychainStore.read(
                relayConnectionKeychainKey,
                service: KeychainStore.sharedService,
                accessGroup: KeychainStore.sharedAccessGroup
            ) {
                // Already absent.
            } else {
                KeychainStore.remove(
                    relayConnectionKeychainKey,
                    service: KeychainStore.sharedService,
                    accessGroup: KeychainStore.sharedAccessGroup
                )
            }
            if let url = relayConnectionURL, FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            return
        }

        if case .found(let existingJSON) = KeychainStore.read(
            relayConnectionKeychainKey,
            service: KeychainStore.sharedService,
            accessGroup: KeychainStore.sharedAccessGroup
        ),
           let existing = try? JSONDecoder().decode(RelayConnection.self, from: Data(existingJSON.utf8)),
           existing == connection {
            if let url = relayConnectionURL, FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            return
        }

        let data = try JSONEncoder().encode(connection)
        guard let json = String(data: data, encoding: .utf8),
              KeychainStore.set(
                  json,
                  forKey: relayConnectionKeychainKey,
                  service: KeychainStore.sharedService,
                  accessGroup: KeychainStore.sharedAccessGroup
              )
        else {
            throw SharedStoreError.relayKeychainWriteFailed
        }
        if let url = relayConnectionURL, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// This device's APNs token (hex), as registered with the relay: the key its muted alerts are
    /// stored under there.
    static var deviceToken: String? {
        get { sharedDefaults?.string(forKey: "deviceToken") }
        set { sharedDefaults?.set(newValue, forKey: "deviceToken") }
    }

    /// Whether the relay pushes its alerts (it has Apple push keys). False on a relay without
    /// them, where the app fetches alerts from the relay instead (`RelayAlertFeed`). Stored
    /// inverted so an install that hasn't asked yet reads as pushing, as every older relay does.
    static var relayAlertsPush: Bool {
        get { !(sharedDefaults?.bool(forKey: "relayAlertsNoPush") ?? false) }
        set { sharedDefaults?.set(!newValue, forKey: "relayAlertsNoPush") }
    }

    /// The key this device's muted alerts are kept under on the relay: its APNs token when it has
    /// one, else an id made up once and kept (a device the relay can't push to still mutes).
    static var alertDeviceKey: String {
        if let deviceToken { return deviceToken }
        if let id = sharedDefaults?.string(forKey: "alertDeviceID") { return id }
        let id = UUID().uuidString.lowercased()
        sharedDefaults?.set(id, forKey: "alertDeviceID")
        return id
    }

    // MARK: - Muted alerts (muted in the Notifications list, honoured by the NSE)

    /// An alert the user muted, by its exact title and body — e.g. a printer without Developer
    /// LAN mode repeating Bambuddy's "MQTT Command verification failed" HMS alert. The NSE
    /// delivers those silently and keeps them out of the history. Same key and schema in the
    /// NSE's copy of this file.
    struct MutedAlert: Codable, Hashable, Sendable {
        var title: String
        var body: String
    }

    static var mutedAlerts: [MutedAlert] {
        get { sharedDefaults?.data(forKey: "mutedAlerts").flatMap { try? JSONDecoder().decode([MutedAlert].self, from: $0) } ?? [] }
        set { sharedDefaults?.set(try? JSONEncoder().encode(newValue), forKey: "mutedAlerts") }
    }

    static func isMuted(title: String, body: String) -> Bool {
        mutedAlerts.contains(MutedAlert(title: title, body: body))
    }

    /// Drops every history entry with this title and body — what muting an alert does to the
    /// copies already in the list.
    static func removeHistory(title: String, body: String) async {
        let outcome = await updateHistory { entries in
            let removed = entries.filter { $0.title == title && $0.body == body }
            entries.removeAll { $0.title == title && $0.body == body }
            return (removed, ())
        }
        for entry in outcome?.dropped ?? [] { deleteHistoryImage(id: entry.id) }
    }
}
