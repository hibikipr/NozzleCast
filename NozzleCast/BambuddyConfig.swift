import Foundation

@Observable
final class BambuddyConfig {
    private static let serverKey = "bambuddy.serverURL"
    private static let apiKeyKeychainKey = "bambuddy.apiKey"

    var serverURLString: String {
        didSet { UserDefaults.standard.set(serverURLString, forKey: Self.serverKey) }
    }

    var apiKey: String {
        didSet { KeychainStore.set(apiKey, forKey: Self.apiKeyKeychainKey) }
    }

    init() {
        serverURLString = UserDefaults.standard.string(forKey: Self.serverKey) ?? ""
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
        KeychainStore.remove(Self.apiKeyKeychainKey)
    }
}
