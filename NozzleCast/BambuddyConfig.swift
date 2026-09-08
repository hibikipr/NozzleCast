import Foundation

@Observable
final class BambuddyConfig {
    /// Legacy UserDefaults key, kept only to migrate a server URL saved before this was
    /// moved into the Keychain alongside the API key.
    private static let legacyServerDefaultsKey = "bambuddy.serverURL"
    private static let serverKeychainKey = "bambuddy.serverURL"
    private static let apiKeyKeychainKey = "bambuddy.apiKey"

    /// Guards the `didSet` persistence below during `init()` — the Keychain items are stored
    /// `kSecAttrAccessibleAfterFirstUnlock`, so a background launch (e.g. a push wake) right
    /// after a device restart, before the phone has been unlocked even once, reads `nil` for
    /// credentials that are genuinely still there. Without this guard, that transient read
    /// failure would flow straight into `didSet` and permanently overwrite the real Keychain
    /// value with an empty string — this is what caused credentials to go blank after a restart.
    private var isInitializing = true

    var serverURLString: String {
        didSet {
            guard !isInitializing else { return }
            KeychainStore.set(serverURLString, forKey: Self.serverKeychainKey)
        }
    }

    var apiKey: String {
        didSet {
            guard !isInitializing else { return }
            KeychainStore.set(apiKey, forKey: Self.apiKeyKeychainKey)
        }
    }

    /// True when the last load couldn't read the Keychain (rather than finding it empty), so the
    /// in-memory values are meaningless and must not be shown to the user or acted on as "not
    /// configured". See `reloadIfStorageWasUnavailable()`.
    private(set) var storageWasUnavailable = false

    init() {
        serverURLString = ""
        apiKey = ""
        loadFromStorage()
    }

    /// Re-reads credentials if — and only if — the previous read was *blocked* rather than empty.
    ///
    /// Confirmed live on an iPad: after a power cycle, the app launched in the background before
    /// the device's first unlock, every Keychain read returned nothing, and the app then showed
    /// blank Bambuddy settings for the rest of that process's life. The credentials were never
    /// gone — force-quitting and relaunching while unlocked brought them straight back. A single
    /// read at `init()` with no retry is what turned a few seconds of unreadability into an
    /// apparently-unconfigured app.
    ///
    /// Call whenever the device may have become unlocked since the last attempt — app foreground
    /// is the reliable one, since being foreground means the device is unlocked by definition.
    func reloadIfStorageWasUnavailable() {
        guard storageWasUnavailable else { return }
        NSLog("NCDEBUG BambuddyConfig retrying a previously-blocked keychain read")
        loadFromStorage()
    }

    private func loadFromStorage() {
        // Guards the `didSet` persistence below for the whole load, not just `init()` — a reload
        // assigns these properties too, and writing a blocked read's empty string back over a
        // good Keychain value is the corruption this flag has always existed to prevent.
        isInitializing = true
        defer { isInitializing = false }

        let storedServer = KeychainStore.read(Self.serverKeychainKey)
        let storedAPIKey = KeychainStore.read(Self.apiKeyKeychainKey)
        storageWasUnavailable = storedServer.isUnavailable || storedAPIKey.isUnavailable

        switch storedServer {
        case .found(let stored):
            serverURLString = stored
        case .notFound:
            if let legacy = UserDefaults.standard.string(forKey: Self.legacyServerDefaultsKey), !legacy.isEmpty {
                // First launch after the server URL moved from UserDefaults to the Keychain:
                // carry the existing value over so the user doesn't have to re-enter it.
                serverURLString = legacy
                KeychainStore.set(legacy, forKey: Self.serverKeychainKey)
                UserDefaults.standard.removeObject(forKey: Self.legacyServerDefaultsKey)
            } else {
                serverURLString = ""
            }
        case .unavailable:
            // Deliberately NOT migrating from the legacy default here: a blocked read says
            // nothing about whether a Keychain value exists, and treating it as absence could
            // resurrect a stale UserDefaults URL over a newer one.
            serverURLString = ""
        }

        apiKey = storedAPIKey.value ?? ""
    }

    var serverURL: URL? {
        guard !serverURLString.isEmpty else { return nil }
        var s = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    var isConfigured: Bool {
        serverURL != nil && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var maskedAPIKey: String {
        guard apiKey.count > 4 else { return apiKey.isEmpty ? "" : "••••" }
        return "••••••••" + apiKey.suffix(4)
    }

    func clear() {
        serverURLString = ""
        apiKey = ""
        KeychainStore.remove(Self.serverKeychainKey)
        KeychainStore.remove(Self.apiKeyKeychainKey)
    }
}
