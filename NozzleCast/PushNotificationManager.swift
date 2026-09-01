import Foundation
import UIKit
import UserNotifications
import FirebaseCore
import FirebaseMessaging

/// Owns the Firebase/APNs push pipeline: configuring Firebase from the user-imported config,
/// registering for remote notifications, and subscribing to Bambuddy's ntfy topic (hashed the
/// same way the user's ntfy app would) once Bambuddy tells us which server/topic it publishes
/// alerts to.
@Observable
final class PushNotificationManager: NSObject {
    static let shared = PushNotificationManager()

    private(set) var isFirebaseConfigured = false
    private(set) var subscribedTopic: String?
    var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private override init() { super.init() }

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
        let fcmTopic = PushTopicHash.firebaseTopic(baseUrl: server, topic: topic, appDefaultBaseUrl: "")
        Messaging.messaging().subscribe(toTopic: fcmTopic) { [weak self] error in
            guard error == nil else { return }
            Task { @MainActor in self?.subscribedTopic = topic }
        }
    }

    func unsubscribeCurrent() {
        guard let config = PushSharedStore.loadNtfyConfig() else { return }
        let fcmTopic = PushTopicHash.firebaseTopic(baseUrl: config.server, topic: config.topic, appDefaultBaseUrl: "")
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
