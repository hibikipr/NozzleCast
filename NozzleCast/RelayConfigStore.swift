import Foundation
import os

/// Persists the user's self-hosted `nozzlecast-relay` connection details (see
/// `github.com/hibikipr/nozzlecast-relay`) — the relay watches Bambuddy's ntfy topic directly and
/// sends an ActivityKit push-to-start request the instant a print starts, closing the gap where
/// `NotificationService.updateLiveActivity`'s own start attempt only works while the app happens
/// to already be foreground (see `../ARCHITECTURE.md#live-activities`). Stored in the shared
/// Keychain Access Group (`kSecAttrAccessibleAfterFirstUnlock`) so credentials stay out of
/// plaintext files, with one-time migration from legacy Application Support `relay-config.json`.
nonisolated enum RelayConfigStore {
    struct Config: Codable, Equatable, Sendable {
        var url: URL
        var authSecret: String
    }

    private static let keychainKey = "relay-config"

    private static var legacyStoredURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("relay-config.json")
    }

    private enum CacheState: Sendable {
        case uninitialized
        case loaded(Config?)
        case unavailable
    }

    private struct StoreState: Sendable {
        var cache: CacheState = .uninitialized
        var generation: UInt64 = 0
    }

    private static let state = OSAllocatedUnfairLock(initialState: StoreState())

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

    private enum StorageError: LocalizedError {
        case keychainWriteFailed

        var errorDescription: String? {
            String(localized: "Couldn't save the relay connection to the Keychain.")
        }
    }

    /// Validates a relay URL string, requiring an `http` or `https` scheme and a non-empty host.
    static func validatedURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        components.scheme = scheme
        return components.url
    }

    /// Validates and stores the relay connection details, replacing any previous config.
    static func save(urlString: String, authSecret: String) throws -> Config {
        let trimmedSecret = authSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = validatedURL(from: urlString) else {
            throw ValidationError.invalidURL
        }
        guard !trimmedSecret.isEmpty else { throw ValidationError.emptySecret }

        let config = Config(url: url, authSecret: trimmedSecret)
        let data = try JSONEncoder().encode(config)
        guard let json = String(data: data, encoding: .utf8) else {
            throw StorageError.keychainWriteFailed
        }

        // The extension's copy first: if it can't be written, nothing is half-saved.
        try PushSharedStore.saveRelayConnection(.init(url: url, authSecret: trimmedSecret))
        guard KeychainStore.set(
            json,
            forKey: keychainKey,
            service: KeychainStore.sharedService,
            accessGroup: KeychainStore.sharedAccessGroup
        ) else {
            try? PushSharedStore.saveRelayConnection(nil)
            throw StorageError.keychainWriteFailed
        }

        if let legacyURL = legacyStoredURL, FileManager.default.fileExists(atPath: legacyURL.path) {
            try? FileManager.default.removeItem(at: legacyURL)
        }
        state.withLock { store in
            store.generation &+= 1
            store.cache = .loaded(config)
        }
        PushSharedStore.relayConfigured = true
        return config
    }

    static func clear() {
        KeychainStore.remove(
            keychainKey,
            service: KeychainStore.sharedService,
            accessGroup: KeychainStore.sharedAccessGroup
        )
        if let legacyURL = legacyStoredURL, FileManager.default.fileExists(atPath: legacyURL.path) {
            try? FileManager.default.removeItem(at: legacyURL)
        }
        state.withLock { store in
            store.generation &+= 1
            store.cache = .uninitialized
        }
        PushSharedStore.relayConfigured = false
        try? PushSharedStore.saveRelayConnection(nil)
        PushSharedStore.relayAlertsActive = false
    }

    private enum CacheLookup: Sendable {
        case hit(Config?)
        case miss(UInt64)
    }

    static func load() -> Config? {
        let lookup: CacheLookup = state.withLock { store in
            if case .loaded(let cached) = store.cache {
                return .hit(cached)
            }
            return .miss(store.generation)
        }
        let startGeneration: UInt64
        switch lookup {
        case .hit(let cached):
            return cached
        case .miss(let generation):
            startGeneration = generation
        }

        let readResult = KeychainStore.read(
            keychainKey,
            service: KeychainStore.sharedService,
            accessGroup: KeychainStore.sharedAccessGroup
        )

        switch readResult {
        case .found(let json):
            let config = try? JSONDecoder().decode(Config.self, from: Data(json.utf8))
            updateCache(.loaded(config), ifGenerationMatches: startGeneration)
            return config

        case .unavailable:
            // Locked before first unlock: do NOT treat as not-configured or delete any legacy file.
            updateCache(.unavailable, ifGenerationMatches: startGeneration)
            return nil

        case .notFound:
            guard let legacyURL = legacyStoredURL,
                  FileManager.default.fileExists(atPath: legacyURL.path)
            else {
                updateCache(.loaded(nil), ifGenerationMatches: startGeneration)
                return nil
            }

            let legacyData: Data
            do {
                legacyData = try Data(contentsOf: legacyURL)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                updateCache(.loaded(nil), ifGenerationMatches: startGeneration)
                return nil
            } catch {
                // File exists on disk but isn't readable right now (e.g. locked before first unlock).
                updateCache(.unavailable, ifGenerationMatches: startGeneration)
                return nil
            }

            guard let legacyConfig = try? JSONDecoder().decode(Config.self, from: legacyData),
                  let validated = validatedURL(from: legacyConfig.url.absoluteString),
                  !legacyConfig.authSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                updateCache(.loaded(nil), ifGenerationMatches: startGeneration)
                return nil
            }

            let normalizedConfig = Config(
                url: validated,
                authSecret: legacyConfig.authSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            if let encoded = try? JSONEncoder().encode(normalizedConfig),
               let json = String(data: encoded, encoding: .utf8),
               KeychainStore.set(
                   json,
                   forKey: keychainKey,
                   service: KeychainStore.sharedService,
                   accessGroup: KeychainStore.sharedAccessGroup
               ) {
                try? FileManager.default.removeItem(at: legacyURL)
                updateCache(.loaded(normalizedConfig), ifGenerationMatches: startGeneration)
            } else {
                // Keychain write did not succeed: keep the legacy file and retry on next read.
                updateCache(.unavailable, ifGenerationMatches: startGeneration)
            }
            return normalizedConfig
        }
    }

    private static func updateCache(_ newCache: CacheState, ifGenerationMatches expectedGeneration: UInt64) {
        state.withLock { store in
            guard store.generation == expectedGeneration else { return }
            store.cache = newCache
        }
    }

    static var isConfigured: Bool {
        load() != nil
    }
}
