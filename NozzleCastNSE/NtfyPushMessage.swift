import Foundation

/// The data-only payload ntfy delivers via Firebase — parsed from the push `userInfo` dict
/// (all string values, as FCM data messages carry them) rather than via `Codable`/`JSONDecoder`.
struct NtfyPushMessage: Sendable {
    var id: String
    var event: String
    var topic: String
    var title: String?
    var message: String?
    var priority: Int?
    var pollID: String?
    var attachmentURL: URL?

    init?(userInfo: [AnyHashable: Any]) {
        guard let id = userInfo["id"] as? String,
              let event = userInfo["event"] as? String,
              let topic = userInfo["topic"] as? String
        else { return nil }
        self.id = id
        self.event = event
        self.topic = topic
        self.title = userInfo["title"] as? String
        self.message = userInfo["message"] as? String
        self.pollID = userInfo["poll_id"] as? String
        if let priorityString = userInfo["priority"] as? String {
            self.priority = Int(priorityString)
        } else {
            self.priority = userInfo["priority"] as? Int
        }
        if let urlString = userInfo["attachment_url"] as? String {
            self.attachmentURL = URL(string: urlString)
        }
    }
}

/// The REST JSON shape ntfy returns from `/{topic}/json`, used both for the `poll_request`
/// follow-up fetch (`?poll=1&id=...`) and to confirm the real attachment schema (verified live:
/// `{"attachment":{"name":...,"type":...,"size":...,"url":...}}`).
private struct NtfyPolledMessage: Decodable {
    struct Attachment: Decodable {
        var url: String
    }

    var id: String
    var event: String
    var topic: String
    var title: String?
    var message: String?
    var priority: Int?
    var attachment: Attachment?
}

extension NtfyPushMessage {
    fileprivate init(polled: NtfyPolledMessage) {
        self.id = polled.id
        self.event = polled.event
        self.topic = polled.topic
        self.title = polled.title
        self.message = polled.message
        self.priority = polled.priority
        self.pollID = nil
        self.attachmentURL = polled.attachment.flatMap { URL(string: $0.url) }
    }
}

enum NtfyPoller {
    static func poll(baseUrl: String, topic: String, messageID: String, authToken: String?) async -> NtfyPushMessage? {
        let trimmed = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: trimmed),
              baseURL.scheme != nil,
              baseURL.host != nil
        else { return nil }

        let endpointURL = baseURL
            .appendingPathComponent(topic)
            .appendingPathComponent("json")
        guard var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "poll", value: "1"),
            URLQueryItem(name: "id", value: messageID),
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        // Poll + follow-up image download must fit well inside the ~30s NSE budget.
        request.timeoutInterval = 8
        if let authToken, !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        guard let (data, response) = try? await NotificationService.downloadSession.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }

        // The poll endpoint returns one JSON object per line (ntfy's newline-delimited format);
        // a single-message poll-by-id response is just that one line.
        guard let line = String(data: data, encoding: .utf8)?
            .split(separator: "\n")
            .first(where: { !$0.isEmpty }),
            let lineData = line.data(using: .utf8),
            let polled = try? JSONDecoder().decode(NtfyPolledMessage.self, from: lineData)
        else { return nil }

        return NtfyPushMessage(polled: polled)
    }
}
