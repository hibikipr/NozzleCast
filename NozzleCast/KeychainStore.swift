import os
import Foundation
import Security

nonisolated enum KeychainStore {
    static let defaultService = "com.noozlecast.bambuddy"
    static let sharedService = "com.victormanuel.NozzleCast"
    private static let sharedAccessGroupSuffix = "com.victormanuel.NozzleCast.shared"

    /// Resolves the shared Keychain Access Group from `Info.plist`'s `AppIdentifierPrefix`.
    /// Returns `nil` when unexpanded/empty (e.g. unsigned simulator or test host runs) so
    /// Keychain operations fall back to the default access group without failing with
    /// `errSecMissingEntitlement`.
    static var sharedAccessGroup: String? {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
              !prefix.isEmpty,
              !prefix.contains("$(")
        else { return nil }
        return prefix + sharedAccessGroupSuffix
    }

    @discardableResult
    static func set(
        _ value: String,
        forKey key: String,
        service: String = defaultService,
        accessGroup: String? = nil
    ) -> Bool {
        let data = Data(value.utf8)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        var status = SecItemUpdate(
            query as CFDictionary,
            [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ] as CFDictionary
        )
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        if status == errSecMissingEntitlement, accessGroup != nil {
            AppLog.storage.debug("keychain write for '\(key, privacy: .private)' missing entitlement for access group '\(accessGroup ?? "", privacy: .private)', falling back to default group")
            return set(value, forKey: key, service: service, accessGroup: nil)
        }
        return status == errSecSuccess
    }

    /// Why this exists instead of just `get` returning nil: "there is no such item" and "the item
    /// is there but this process cannot read it right now" are completely different facts, and
    /// collapsing them into `nil` is what let a locked-device read look like "the user has no
    /// credentials." Items here are `kSecAttrAccessibleAfterFirstUnlock`, so a launch before the
    /// device's first unlock since boot — a push wake right after a restart, say — reads nothing
    /// while the real values sit untouched in the Keychain.
    enum ReadResult: Equatable, Sendable {
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
    static func read(
        _ key: String,
        service: String = defaultService,
        accessGroup: String? = nil
    ) -> ReadResult {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
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
        case errSecMissingEntitlement where accessGroup != nil:
            AppLog.storage.debug("keychain read for '\(key, privacy: .private)' missing entitlement for access group '\(accessGroup ?? "", privacy: .private)', falling back to default group")
            return read(key, service: service, accessGroup: nil)
        default:
            AppLog.storage.debug("keychain read for '\(key, privacy: .private)' unavailable (OSStatus \(status, privacy: .public))")
            return .unavailable(status)
        }
    }

    static func get(
        _ key: String,
        service: String = defaultService,
        accessGroup: String? = nil
    ) -> String? {
        read(key, service: service, accessGroup: accessGroup).value
    }

    static func remove(
        _ key: String,
        service: String = defaultService,
        accessGroup: String? = nil
    ) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecMissingEntitlement, accessGroup != nil {
            remove(key, service: service, accessGroup: nil)
        }
    }
}
