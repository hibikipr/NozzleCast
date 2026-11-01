import Foundation

/// Bambuddy's alerts through the user's nozzlecast-relay (relay v1.7.0+, README "Bambuddy
/// alerts"). Bambuddy's Webhook provider posts each alert to the relay, and the relay pushes it to
/// this device as an ordinary APNs alert, unless this device muted it. A muted alert then never
/// reaches the Lock Screen, which the notification extension alone can't do: iOS lets it blank a
/// push, not drop it.
///
/// Once the relay reports that Bambuddy's webhook reaches it, the app switches off its own
/// ntfy/Firebase subscription and the alert-log fallback, so nothing arrives twice.
enum RelayAlertClient {
    /// Whether the relay delivers Bambuddy's alerts: false with no relay or before Bambuddy's
    /// webhook has reached it; nil when the relay couldn't be asked (an older relay answers 404,
    /// which is false).
    static func isDelivering() async -> Bool? {
        guard let config = RelayConfigStore.load() else { return false }
        var request = URLRequest(url: config.url.appendingPathComponent("alerts").appendingPathComponent("status"))
        request.setValue("Bearer \(config.authSecret)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200?:
                struct Status: Decodable { var active: Bool }
                return (try? JSONDecoder().decode(Status.self, from: data))?.active ?? false
            case 404?:
                return false
            default:
                return nil
            }
        } catch {
            NSLog("NCDEBUG relay alert status failed: %@", String(describing: error))
            return nil
        }
    }

    /// Sends this device's muted alerts to the relay, which drops them before they're pushed. After
    /// every mute and unmute, and whenever the device token is registered again.
    static func syncMutes() async {
        guard let config = RelayConfigStore.load(), let token = PushSharedStore.deviceToken else { return }
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
