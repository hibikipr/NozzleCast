import Foundation

/// Everything shared between the main app and the NotificationService extension, which runs as
/// a separate process and can't see the main app's Keychain or UserDefaults. Kept in the App
/// Group container instead — a plain JSON file rather than Core Data, since our needs are much
/// smaller than a full multi-subscription client's: exactly one ntfy topic (Bambuddy's alerts),
/// and a short local notification history for the in-app list.
nonisolated enum PushSharedStore {
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

    /// Read-modify-write of the history file under an `NSFileCoordinator` write lock. The app
    /// (mark-all-read, clear) and the notification extension (one append per push, possibly
    /// several at once) are separate processes rewriting the same file; uncoordinated, whichever
    /// wrote last silently discarded the other's change — a lost history entry, or a
    /// mark-all-read that didn't stick.
    ///
    /// `@concurrent`, not just `async`: `coordinate(writingItemAt:...)` blocks its calling thread
    /// until the lock is free, and a plain nonisolated `async` function runs on the caller's
    /// actor by default (`SWIFT_APPROACHABLE_CONCURRENCY`). Every caller here is a `@MainActor`
    /// SwiftUI view, so without this the wait for the NSE's write lock happened on the main
    /// thread — the app hung while the extension held the file.
    /// `transform` returns the entries that fell out of the update (dropped for exceeding
    /// `historyLimit`, or empty) rather than reporting them through a captured var — a closure
    /// passed into a `@concurrent` function runs in a different isolation domain than its
    /// caller, so mutating a var the caller captured would be a data race.
    @discardableResult
    @concurrent
    private static func updateHistory(_ transform: @Sendable (inout [HistoryEntry]) -> [HistoryEntry]) async -> [HistoryEntry] {
        var coordinationError: NSError?
        var dropped: [HistoryEntry] = []
        NSFileCoordinator().coordinate(writingItemAt: historyURL, options: .forMerging, error: &coordinationError) { url in
            var entries: [HistoryEntry] = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([HistoryEntry].self, from: $0) } ?? []
            dropped = transform(&entries)
            guard let data = try? JSONEncoder().encode(entries) else { return }
            try? data.write(to: url, options: .atomic)
        }
        if let coordinationError {
            NSLog("NCDEBUG notification history coordination failed: %@", coordinationError.localizedDescription)
        }
        return dropped
    }

    static func appendHistory(_ entry: HistoryEntry) async {
        let dropped = await updateHistory { entries in
            entries.removeAll { $0.id == entry.id }
            entries.insert(entry, at: 0)
            guard entries.count > historyLimit else { return [] }
            let dropped = Array(entries.suffix(entries.count - historyLimit))
            entries.removeLast(dropped.count)
            return dropped
        }
        for old in dropped { deleteHistoryImage(id: old.id) }
    }

    static func loadHistory() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        return (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    static func clearHistory() async {
        await updateHistory { $0.removeAll(); return [] }
        try? FileManager.default.removeItem(at: historyImagesDir)
    }

    static func unreadCount() -> Int {
        loadHistory().filter(\.isUnread).count
    }

    static func markAllRead() async {
        guard loadHistory().contains(where: \.isUnread) else { return }
        await updateHistory { entries in
            for i in entries.indices { entries[i].isRead = true }
            return []
        }
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

    // MARK: - Live Activity preferences (read by both the main app and the NSE, which can also
    // start/update/end activities on its own from a push — see NotificationService.swift)

    private static var sharedDefaults: UserDefaults { UserDefaults(suiteName: appGroup)! }

    /// Master on/off switch exposed in Settings, per Apple's Live Activity guidance: "make it
    /// easy for people to turn them off in your app" rather than only via the system Settings
    /// app. Defaults to on since that's the existing behavior for everyone before this setting
    /// existed.
    static var liveActivitiesEnabled: Bool {
        get { sharedDefaults.object(forKey: "liveActivitiesEnabled") as? Bool ?? true }
        set { sharedDefaults.set(newValue, forKey: "liveActivitiesEnabled") }
    }

    /// Whether the printer's live camera frame is shown on the Lock Screen Live Activity.
    /// Defaults to on (existing behavior), but per Apple's guidance to "let people configure
    /// whether to show sensitive data," a live camera feed of someone's workshop is exactly the
    /// kind of thing worth an explicit opt-out for — the Lock Screen is visible to anyone who
    /// picks up the phone.
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
