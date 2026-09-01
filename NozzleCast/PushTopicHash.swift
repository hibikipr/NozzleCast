import Foundation
import CryptoKit

/// Firebase Cloud Messaging topic-name computation for a self-hosted ntfy server, ported
/// byte-for-byte from the user's own ntfy iOS app (`ntfy-ios/ntfy/Utils/Helpers.swift`) — the
/// self-hosted ntfy relay that publishes to their shared Firebase project computes subscriber
/// topics this exact way, so any deviation here means notifications silently never arrive.
enum PushTopicHash {
    static func normalizeBaseUrl(_ baseUrl: String) -> String {
        var normalized = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private static func topicUrl(baseUrl: String, topic: String) -> String {
        "\(normalizeBaseUrl(baseUrl))/\(topic)"
    }

    private static func topicHash(baseUrl: String, topic: String) -> String {
        let data = Data(topicUrl(baseUrl: normalizeBaseUrl(baseUrl), topic: topic).utf8)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// `appDefaultBaseUrl` is the ntfy server the *reference app* ships bundled with, whose
    /// subscribers get the raw topic name unhashed. NozzleCast always talks to a self-hosted
    /// server pulled from Bambuddy's own config, never that default, so this always takes the
    /// hashed branch in practice — the comparison is kept only to mirror the source exactly.
    static func firebaseTopic(baseUrl: String, topic: String, appDefaultBaseUrl: String) -> String {
        normalizeBaseUrl(baseUrl) == normalizeBaseUrl(appDefaultBaseUrl)
            ? topic
            : topicHash(baseUrl: baseUrl, topic: topic)
    }
}
