import Foundation

/// Persists a user-imported `GoogleService-Info.plist` so Firebase can be configured
/// programmatically at launch — NozzleCast ships with no Firebase config baked in, since it
/// reuses the user's own self-hosted Firebase project (the same one their ntfy app uses) rather
/// than requiring a NozzleCast-specific Firebase project of our own.
enum FirebaseConfigStore {
    private static let requiredKeys = ["API_KEY", "GCM_SENDER_ID", "PROJECT_ID", "GOOGLE_APP_ID"]
    /// Firebase's `FIRApp.configure` traps with an uncatchable `NSException` on a malformed
    /// `GOOGLE_APP_ID`, so this has to be validated before ever handing the file to the SDK.
    private static let googleAppIDPattern = #"^\d+:\d+:ios:[0-9a-fA-F]+$"#

    private static var storedURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("GoogleService-Info.plist")
    }

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

    /// Validates and stores the plist at `sourceURL`, replacing any previously imported config.
    static func importConfig(from sourceURL: URL) throws {
        guard let data = try? Data(contentsOf: sourceURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw ImportError.unreadable }

        let missing = requiredKeys.filter { plist[$0] == nil }
        guard missing.isEmpty else { throw ImportError.missingKeys(missing) }

        guard let appID = plist["GOOGLE_APP_ID"] as? String,
              appID.range(of: googleAppIDPattern, options: .regularExpression) != nil
        else { throw ImportError.invalidAppID }

        try data.write(to: storedURL, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: storedURL)
    }

    static var isConfigured: Bool {
        FileManager.default.fileExists(atPath: storedURL.path)
    }

    static var configuredFileURL: URL? {
        isConfigured ? storedURL : nil
    }

    /// Best-effort summary shown in Settings — Firebase itself re-validates when it configures.
    static var projectID: String? {
        guard let data = try? Data(contentsOf: storedURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["PROJECT_ID"] as? String
    }
}
