import Foundation

@Observable
final class BambuddyConfig {
    /// Legacy UserDefaults key, kept only to migrate a server URL saved before this was
    /// moved into the Keychain alongside the API key.
    private static let legacyServerDefaultsKey = "bambuddy.serverURL"
    private static let serverKeychainKey = "bambuddy.serverURL"
    private static let apiKeyKeychainKey = "bambuddy.apiKey"

    var serverURLString: String {
        didSet { KeychainStore.set(serverURLString, forKey: Self.serverKeychainKey) }
    }

    var apiKey: String {
        didSet { KeychainStore.set(apiKey, forKey: Self.apiKeyKeychainKey) }
    }

    init() {
        if let stored = KeychainStore.get(Self.serverKeychainKey) {
            serverURLString = stored
        } else if let legacy = UserDefaults.standard.string(forKey: Self.legacyServerDefaultsKey), !legacy.isEmpty {
            // First launch after the server URL moved from UserDefaults to the Keychain:
            // carry the existing value over so the user doesn't have to re-enter it.
            serverURLString = legacy
            KeychainStore.set(legacy, forKey: Self.serverKeychainKey)
            UserDefaults.standard.removeObject(forKey: Self.legacyServerDefaultsKey)
        } else {
            serverURLString = ""
        }
        apiKey = KeychainStore.get(Self.apiKeyKeychainKey) ?? ""
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
