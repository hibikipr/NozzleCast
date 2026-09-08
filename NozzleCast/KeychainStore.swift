import Foundation
import Security

enum KeychainStore {
    private static let service = "com.noozlecast.bambuddy"

    static func set(_ value: String, forKey key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    /// Why this exists instead of just `get` returning nil: "there is no such item" and "the item
    /// is there but this process cannot read it right now" are completely different facts, and
    /// collapsing them into `nil` is what let a locked-device read look like "the user has no
    /// credentials." Items here are `kSecAttrAccessibleAfterFirstUnlock`, so a launch before the
    /// device's first unlock since boot — a push wake right after a restart, say — reads nothing
    /// while the real values sit untouched in the Keychain.
    enum ReadResult: Equatable {
        case found(String)
        /// No such item. The genuine "not configured" answer.
        case notFound
        /// The item could not be read right now (device locked, or any status we don't recognize).
        /// Callers should retry later rather than treat this as absence.
        case unavailable(OSStatus)

        var value: String? {
            if case .found(let value) = self { return value }
            return nil
        }

        var isUnavailable: Bool {
            if case .unavailable = self { return true }
            return false
        }
    }

    /// Note the default: anything that isn't an outright success or `errSecItemNotFound` is
    /// treated as `.unavailable`, not as absence. Guessing "absent" for an unrecognized status is
    /// precisely the failure mode this type exists to prevent, and retrying costs nothing.
    static func read(_ key: String) -> ReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
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
        default:
            NSLog("NCDEBUG keychain read for '%@' unavailable (OSStatus %d)", key, status)
            return .unavailable(status)
        }
    }

    static func get(_ key: String) -> String? {
        read(key).value
    }

    static func remove(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
