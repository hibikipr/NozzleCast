import Foundation

/// Persists the user's self-hosted `nozzlecast-relay` connection details (see
/// `github.com/hibikipr/nozzlecast-relay`) — the relay watches Bambuddy's ntfy topic directly and
/// sends an ActivityKit push-to-start request the instant a print starts, closing the gap where
/// `NotificationService.updateLiveActivity`'s own start attempt only works while the app happens
/// to already be foreground (see `../ARCHITECTURE.md#live-activities`). Only the main app process
/// needs this — the NSE never talks to the relay — so this lives in Application Support like
/// `FirebaseConfigStore`, not the shared App Group.
enum RelayConfigStore {
    struct Config: Codable, Equatable {
        var url: URL
        var authSecret: String
    }

    private static var storedURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("relay-config.json")
    }

    enum ValidationError: LocalizedError {
        case invalidURL
        case emptySecret

        var errorDescription: String? {
            switch self {
            case .invalidURL: String(localized: "Enter a valid relay URL, e.g. https://relay.example.com.")
            case .emptySecret: String(localized: "Enter the relay's registration secret.")
            }
        }
    }

    /// Validates and stores the relay connection details, replacing any previous config.
    static func save(urlString: String, authSecret: String) throws -> Config {
        let trimmedURLString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = authSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURLString), url.scheme != nil, url.host != nil else {
            throw ValidationError.invalidURL
        }
        guard !trimmedSecret.isEmpty else { throw ValidationError.emptySecret }

        let config = Config(url: url, authSecret: trimmedSecret)
        let data = try JSONEncoder().encode(config)
        try data.write(to: storedURL, options: .atomic)
        PushSharedStore.relayConfigured = true
        return config
    }

    static func clear() {
        try? FileManager.default.removeItem(at: storedURL)
        PushSharedStore.relayConfigured = false
    }

    static func load() -> Config? {
        guard let data = try? Data(contentsOf: storedURL) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    static var isConfigured: Bool {
        load() != nil
    }
}
