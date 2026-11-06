import Foundation

/// Bambuddy's alerts through the user's nozzlecast-relay (relay v1.7.0+, README "Bambuddy
/// alerts"). Bambuddy's Webhook provider posts each alert to the relay, and the relay pushes it to
/// this device as an ordinary APNs alert, unless this device muted it. A muted alert then never
/// reaches the Lock Screen, which the notification extension alone can't do: iOS lets it blank a
/// push, not drop it.
///
/// Once the relay reports that Bambuddy's webhook reaches it, the app switches off its own
/// ntfy/Firebase subscription and the alert-log fallback, so nothing arrives twice. A relay
/// without Apple push keys (relay v1.8.0+) keeps the alerts for the app to fetch instead, with the
/// same mutes applied: see `RelayAlertFeed`.
enum RelayAlertClient {
    /// How the relay delivers Bambuddy's alerts: `active` once Bambuddy's webhook has reached it,
    /// `pushes` false on a relay without Apple push keys (then `RelayAlertFeed` fetches them).
    struct Delivery: Equatable {
        var active: Bool
        var pushes: Bool
    }

    /// Inactive with no relay or before Bambuddy's webhook has reached it; nil when the relay
    /// couldn't be asked (an older relay answers 404, which is inactive).
    static func delivery() async -> Delivery? {
        guard let config = RelayConfigStore.load() else { return Delivery(active: false, pushes: true) }
        var request = URLRequest(url: config.url.appendingPathComponent("alerts").appendingPathComponent("status"))
        request.setValue("Bearer \(config.authSecret)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200?:
                // `pushes` is new in relay v1.8.0; every older relay pushes.
                struct Status: Decodable { var active: Bool; var pushes: Bool? }
                let status = try? JSONDecoder().decode(Status.self, from: data)
                return Delivery(active: status?.active ?? false, pushes: status?.pushes ?? true)
            case 404?:
                return Delivery(active: false, pushes: true)
            default:
                return nil
            }
        } catch {
            NSLog("NCDEBUG relay alert status failed: %@", String(describing: error))
            return nil
        }
    }

    /// One alert from the relay's feed (`GET /alerts`), already without this device's mutes.
    struct FeedItem: Decodable {
        var id: Int
        var receivedAt: String
        var title: String
        var body: String
        var event: String?
        var printer: String?
        var photoID: String?
        var timeSensitive: Bool?
    }

    struct Feed: Decodable {
        var items: [FeedItem]
        var latestId: Int
    }

    /// The alerts the relay received after `after`, minus the ones this device muted. With `after`
    /// nil, no items: only the id to continue from.
    static func fetchAlerts(after: Int?) async throws -> Feed {
        guard let config = RelayConfigStore.load() else { throw URLError(.badURL) }
        var components = URLComponents(url: config.url.appendingPathComponent("alerts"), resolvingAgainstBaseURL: false)
        var query = [URLQueryItem(name: "device", value: PushSharedStore.alertDeviceKey)]
        if let after { query.append(URLQueryItem(name: "after", value: String(after))) }
        components?.queryItems = query
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(config.authSecret)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Relay answered HTTP \(status)"]) }
        return try JSONDecoder().decode(Feed.self, from: data)
    }

    /// A relay alert's photo (`GET /alert-photo/:id`), or nil when it's gone or unreachable.
    static func photo(id: String) async -> Data? {
        guard let config = RelayConfigStore.load() else { return nil }
        var request = URLRequest(url: config.url.appendingPathComponent("alert-photo").appendingPathComponent(id))
        request.setValue("Bearer \(config.authSecret)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// Sends this device's muted alerts to the relay, which drops them before they're pushed. After
    /// every mute and unmute, and whenever the device token is registered again.
    static func syncMutes() async {
        guard let config = RelayConfigStore.load() else { return }
        let token = PushSharedStore.alertDeviceKey
        struct Body: Encodable {
            var token: String
            var alerts: [PushSharedStore.MutedAlert]
        }
        var request = URLRequest(url: config.url.appendingPathComponent("muted-alerts"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(config.authSecret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(Body(token: token, alerts: PushSharedStore.mutedAlerts))
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status != 200 { NSLog("NCDEBUG relay muted-alerts sync HTTP %d", status) }
        } catch {
            NSLog("NCDEBUG relay muted-alerts sync failed: %@", String(describing: error))
        }
    }
}
