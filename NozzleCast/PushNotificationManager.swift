import ActivityKit
import Foundation
import UIKit
import UserNotifications
import FirebaseCore
import FirebaseMessaging

/// Owns the Firebase/APNs push pipeline: configuring Firebase from the user-imported config,
/// registering for remote notifications, and subscribing to Bambuddy's ntfy topic once Bambuddy
/// tells us which server/topic it publishes alerts to.
@Observable
final class PushNotificationManager: NSObject {
    static let shared = PushNotificationManager()

    /// The user's ntfy server is baked into their own ntfy iOS app as *that app's* bundled
    /// default (`APP_BASE_URL` in `ntfy-ios/ntfy.xcodeproj`), so per ntfy's own topic-hashing
    /// rule its Firebase relay publishes under the raw, unhashed topic name rather than a
    /// per-server hash — confirmed by a live test push that only the hashed subscription missed.
    /// Matching that here means comparing against this same server, not hashing unconditionally.
    private static let knownNtfyDefaultBaseUrl = "https://ntfy.townsville.cc"

    private(set) var isFirebaseConfigured = false
    /// Whether we've asked Firebase to subscribe to the saved ntfy topic. This reflects intent,
    /// not a confirmed round-trip: `Messaging.subscribe(toTopic:)`'s completion handler only
    /// signals local SDK readiness, not actual delivery, and on the auto-resubscribe done from
    /// `configureFirebaseIfNeeded()` at launch it may not fire before Settings is viewed — so
    /// gating this on that callback left the UI stuck on "Tap to subscribe" even while pushes
    /// were arriving successfully. Seeding it from the persisted config on init, and setting it
    /// as soon as a subscribe is issued rather than waiting on the callback, keeps it truthful.
    private(set) var subscribedTopic: String?
    var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// The push-to-start token most recently registered with the relay, if any — reflects intent
    /// (a register call was issued), not delivery confirmation, same caveat as `subscribedTopic`.
    private(set) var registeredPushToStartToken: String?
    private var pushToStartObservationTask: Task<Void, Never>?

    private override init() {
        subscribedTopic = PushSharedStore.loadNtfyConfig()?.topic
        super.init()
    }

    /// Call once at app launch, after Firebase's own config file (if any) has been imported.
    func configureFirebaseIfNeeded() {
        guard !isFirebaseConfigured, let path = FirebaseConfigStore.configuredFileURL?.path else { return }
        guard let options = FirebaseOptions(contentsOfFile: path) else { return }
        FirebaseApp.configure(options: options)
        Messaging.messaging().delegate = self
        isFirebaseConfigured = true

        // A topic subscription requested before Firebase was configured (or before this launch)
        // needs to be re-issued now that Messaging is live.
        if let config = PushSharedStore.loadNtfyConfig() {
            subscribe(server: config.server, topic: config.topic)
        }

        startObservingPushToStartTokenIfConfigured()
    }

    /// Starts (once) an app-lifetime task that registers every push-to-start token ActivityKit
    /// issues or rotates with the relay. Safe to call repeatedly — a no-op once the observation
    /// task is already running. Call again after the relay config changes (e.g. the user just
    /// saved a URL/secret in Settings) so a config saved after launch starts observing too.
    func startObservingPushToStartTokenIfConfigured() {
        guard pushToStartObservationTask == nil, RelayConfigStore.isConfigured else { return }
        pushToStartObservationTask = Task {
            for await tokenData in Activity<PrintActivityAttributes>.pushToStartTokenUpdates {
                await registerPushToStartToken(tokenData)
            }
        }
    }

    /// POSTs a push-to-start token to the relay's `/register` endpoint. `environment` mirrors
    /// which APNs environment this build's `aps-environment` entitlement actually uses — Xcode
    /// sets that from the provisioning profile at build time (development for a local/Debug
    /// build, production for a distribution/Release build), so `#if DEBUG` tracks it closely
    /// enough without parsing the embedded provisioning profile.
    private func registerPushToStartToken(_ tokenData: Data) async {
        guard let config = RelayConfigStore.load() else { return }
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif

        var request = URLRequest(url: config.url.appendingPathComponent("register"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.authSecret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["token": token, "environment": environment])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                print("NozzleCast: relay token registration failed with unexpected response")
                return
            }
            registeredPushToStartToken = token
        } catch {
            print("NozzleCast: relay token registration failed: \(error)")
        }
    }

    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run { self.authorizationStatus = settings.authorizationStatus }
    }

    /// Requests notification permission and registers for remote (APNs) notifications. Safe to
    /// call even if Firebase isn't configured yet — registration just won't produce a usable
    /// FCM token until it is.
    func requestAuthorization() async throws {
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await refreshAuthorizationStatus()
        guard granted else { return }
        await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
    }

    func handleAPNsToken(_ deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }

    /// Subscribes to the FCM topic that mirrors ntfy's `server`+`topic`, and remembers the ntfy
    /// config (server, topic, auth token) in the App Group container so the Notification
    /// Service Extension can fall back to a REST poll for `poll_request`-style pushes.
    func subscribe(server: String, topic: String, authToken: String? = nil) {
        PushSharedStore.saveNtfyConfig(.init(server: server, topic: topic, authToken: authToken))
        guard isFirebaseConfigured else { return }
        subscribedTopic = topic
        let fcmTopic = PushTopicHash.firebaseTopic(baseUrl: server, topic: topic, appDefaultBaseUrl: Self.knownNtfyDefaultBaseUrl)
        Messaging.messaging().subscribe(toTopic: fcmTopic) { error in
            if let error {
                print("NozzleCast: FCM topic subscribe failed for \(fcmTopic): \(error)")
            }
        }
    }

    func unsubscribeCurrent() {
        guard let config = PushSharedStore.loadNtfyConfig() else { return }
        let fcmTopic = PushTopicHash.firebaseTopic(baseUrl: config.server, topic: config.topic, appDefaultBaseUrl: Self.knownNtfyDefaultBaseUrl)
        Messaging.messaging().unsubscribe(fromTopic: fcmTopic)
        PushSharedStore.clearNtfyConfig()
        subscribedTopic = nil
    }
}

extension PushNotificationManager: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        // No server-side device registry to update — subscriptions are purely topic-based.
    }
}
