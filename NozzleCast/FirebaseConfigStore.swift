import Foundation
import os

/// Persists a user-imported `GoogleService-Info.plist` so Firebase can be configured
/// programmatically at launch — NozzleCast ships with no Firebase config baked in, since it
/// reuses the user's own self-hosted Firebase project (the same one their ntfy app uses) rather
/// than requiring a NozzleCast-specific Firebase project of our own.
nonisolated enum FirebaseConfigStore {
    private static let requiredKeys = ["API_KEY", "GCM_SENDER_ID", "PROJECT_ID", "GOOGLE_APP_ID"]
    /// Firebase's `FIRApp.configure` traps with an uncatchable `NSException` on a malformed
    /// `GOOGLE_APP_ID`, so this has to be validated before ever handing the file to the SDK.
    private static let googleAppIDPattern = #"^\d+:\d+:ios:[0-9a-fA-F]+$"#

    private static var appSupportDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    private static var configFileURL: URL? {
        appSupportDirectory?.appendingPathComponent("GoogleService-Info.plist")
    }

    private enum CacheState: Sendable {
        case uninitialized
        case resolved(url: URL?, projectID: String?)
        case unavailable
    }

    private struct StoreState: Sendable {
        var cache: CacheState = .uninitialized
        var generation: UInt64 = 0
    }

    private static let state = OSAllocatedUnfairLock(initialState: StoreState())

    enum ImportError: LocalizedError {
        case missingKeys([String])
        case invalidAppID
        case unreadable

        var errorDescription: String? {
            switch self {
            case .missingKeys(let keys):
                String(localized: "This file is missing required keys: \(keys.joined(separator: ", ")).")
            case .invalidAppID:
                String(localized: "The GOOGLE_APP_ID in this file doesn't look like a valid iOS app ID.")
            case .unreadable:
                String(localized: "Couldn't read this file as a property list.")
            }
        }
    }

    /// Validates raw plist bytes and returns the trimmed `PROJECT_ID`. All 4 required keys must be
    /// non-empty trimmed strings and `GOOGLE_APP_ID` must match Firebase's iOS app ID format.
    @discardableResult
    static func validate(_ data: Data) throws -> String {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw ImportError.unreadable }

        let missing = requiredKeys.filter { key in
            guard let raw = plist[key] as? String else { return true }
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard missing.isEmpty else { throw ImportError.missingKeys(missing) }

        let appID = (plist["GOOGLE_APP_ID"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard appID.range(of: googleAppIDPattern, options: .regularExpression) != nil
        else { throw ImportError.invalidAppID }

        return (plist["PROJECT_ID"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Validates and stores the plist at `sourceURL`, replacing any previously imported config.
    static func importConfig(from sourceURL: URL) throws {
        guard let data = try? Data(contentsOf: sourceURL) else {
            throw ImportError.unreadable
        }
        let trimmedProjectID = try validate(data)

        guard let dir = appSupportDirectory, let destURL = configFileURL else {
            throw ImportError.unreadable
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: destURL, options: .atomic)

        state.withLock { store in
            store.generation &+= 1
            store.cache = .resolved(url: destURL, projectID: trimmedProjectID)
        }
    }

    static func clear() {
        if let url = configFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        state.withLock { store in
            store.generation &+= 1
            store.cache = .uninitialized
        }
    }

    private enum CacheLookup: Sendable {
        case hit(url: URL?, projectID: String?)
        case miss(UInt64)
    }

    private static func resolvedConfig() -> (url: URL?, projectID: String?) {
        let lookup: CacheLookup = state.withLock { store in
            if case .resolved(let url, let projectID) = store.cache {
                return .hit(url: url, projectID: projectID)
            }
            return .miss(store.generation)
        }
        let startGeneration: UInt64
        switch lookup {
        case .hit(let url, let projectID):
            return (url, projectID)
        case .miss(let generation):
            startGeneration = generation
        }

        guard let url = configFileURL,
              FileManager.default.fileExists(atPath: url.path)
        else {
            updateCache(.resolved(url: nil, projectID: nil), ifGenerationMatches: startGeneration)
            return (nil, nil)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            updateCache(.resolved(url: nil, projectID: nil), ifGenerationMatches: startGeneration)
            return (nil, nil)
        } catch {
            // File exists on disk but isn't readable yet (e.g. locked before first unlock).
            updateCache(.unavailable, ifGenerationMatches: startGeneration)
            return (nil, nil)
        }

        guard let projectID = try? validate(data) else {
            updateCache(.resolved(url: nil, projectID: nil), ifGenerationMatches: startGeneration)
            return (nil, nil)
        }

        updateCache(.resolved(url: url, projectID: projectID), ifGenerationMatches: startGeneration)
        return (url, projectID)
    }

    private static func updateCache(_ newCache: CacheState, ifGenerationMatches expectedGeneration: UInt64) {
        state.withLock { store in
            guard store.generation == expectedGeneration else { return }
            store.cache = newCache
        }
    }

    static var isConfigured: Bool {
        resolvedConfig().url != nil
    }

    static var configuredFileURL: URL? {
        resolvedConfig().url
    }

    /// Best-effort summary shown in Settings — validated identically before saving or configuring.
    static var projectID: String? {
        resolvedConfig().projectID
    }
}
