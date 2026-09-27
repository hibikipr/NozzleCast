import ActivityKit
import Foundation
import UIKit
import UserNotifications
import FirebaseCore
import FirebaseMessaging
import NozzleCastShared

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

    /// Durable counterpart to `registeredPushToStartToken`, surviving relaunches — needed so a
    /// token rotation can be told apart from "first registration ever" across process restarts.
    /// Apple rotates the push-to-start token periodically (delivered via
    /// `pushToStartTokenUpdates`), and the relay's token store is a flat list keyed only by token
    /// string with no device identity: it keeps every token this device has ever registered until
    /// APNs explicitly rejects one (410), and sends push-to-start to *all* of them on every print
    /// start. Without this, a rotation just adds a second live token for the same device instead
    /// of replacing the first, and both fire — two separate Live Activities for one print.
    /// Confirmed live: a token from 2026-09-04 still sitting on the relay alongside a fresh one
    /// from 2026-09-26 for the same install. UserDefaults, not Keychain: this token is already
    /// sent to the relay in the open and isn't a credential, and — unlike the Bambuddy/relay
    /// config — nothing here needs to survive a locked-device background wake before first unlock.
    private static let lastRegisteredPushToStartTokenDefaultsKey = "PushNotificationManager.lastRegisteredPushToStartToken"
    private static var persistedLastRegisteredPushToStartToken: String? {
        get { UserDefaults.standard.string(forKey: lastRegisteredPushToStartTokenDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastRegisteredPushToStartTokenDefaultsKey) }
    }
    private var pushToStartObservationTask: Task<Void, Never>?
    private var activityDiscoveryTask: Task<Void, Never>?
    /// One push-token-observing child task per discovered activity, keyed by `Activity.id` — so a
    /// second `activityUpdates` event for the same activity (e.g. a token rotation notice) doesn't
    /// spawn a duplicate observer.
    private var activityPushTokenTasks: [String: Task<Void, Never>] = [:]

    private override init() {
        subscribedTopic = PushSharedStore.loadNtfyConfig()?.topic
        super.init()
    }

    /// Arms both ActivityKit token observers. Call once at every app launch, unconditionally.
    ///
    /// Deliberately NOT part of `configureFirebaseIfNeeded()`, where these two calls used to
    /// live: ActivityKit and Firebase share nothing. The push-to-start and per-activity push
    /// tokens come from ActivityKit and go straight to the relay over plain URLSession — Firebase
    /// is only ever involved in the separate ntfy/FCM alert path. Sitting behind that method's
    /// early-return guards meant observation silently never started on two real launch paths:
    /// when no Firebase config file has been imported (the first `guard` returns), and on any
    /// repeat call once `isFirebaseConfigured` was already true. In both cases the relay could be
    /// fully configured and the app would still never observe a single push-to-start token, with
    /// the only recovery being for the user to happen to re-save the relay sheet.
    ///
    /// Both callees keep their own `RelayConfigStore.isConfigured` guard and their own
    /// already-running guard, so this stays safe to call repeatedly.
    func startObservingActivityKitTokens() {
        startObservingPushToStartTokenIfConfigured()
        startObservingActivityPushTokensIfConfigured()
    }

    /// Call once at app launch, after Firebase's own config file (if any) has been imported.
    /// Only concerns the ntfy/FCM alert path — see `startObservingActivityKitTokens()` for the
    /// ActivityKit side, which must not be gated on any of this.
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

    /// Starts (once) an app-lifetime task that registers every push-to-start token ActivityKit
    /// issues or rotates with the relay. Safe to call repeatedly — a no-op once the observation
    /// task is already running. Call again after the relay config changes (e.g. the user just
    /// saved a URL/secret in Settings) so a config saved after launch starts observing too.
    func startObservingPushToStartTokenIfConfigured() {
        // Already running is the overwhelmingly common case now that this is re-armed on every
        // activation, and logging it would bury the device log during a debugging session. Only
        // the actionable case -- armed too early to read the relay config -- is worth a line.
        guard pushToStartObservationTask == nil else { return }
        guard RelayConfigStore.isConfigured else {
            NSLog("NCDEBUG push-to-start observation not started: relay config not readable yet")
            return
        }
        NSLog("NCDEBUG push-to-start observation starting")
        pushToStartObservationTask = Task {
            for await tokenData in Activity<PrintActivityAttributes>.pushToStartTokenUpdates {
                NSLog("NCDEBUG push-to-start token received (%d bytes), registering with relay", tokenData.count)
                await registerPushToStartToken(tokenData)
            }
        }
    }

    /// POSTs a push-to-start token to the relay's `/register` endpoint. `environment` is read
    /// from the embedded provisioning profile's actual `aps-environment` entitlement — see
    /// `APNSEnvironment` for why inferring it from `#if DEBUG` was wrong for one real build
    /// configuration.
    private func registerPushToStartToken(_ tokenData: Data) async {
        guard let config = RelayConfigStore.load() else {
            NSLog("NCDEBUG push-to-start token registration skipped: no relay configured")
            return
        }
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        let environment = APNSEnvironment.current
        let previousToken = Self.persistedLastRegisteredPushToStartToken

        var request = URLRequest(url: config.url.appendingPathComponent("register"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.authSecret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["token": token, "environment": environment])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                NSLog("NCDEBUG relay token registration failed with unexpected response: %@", String(describing: response))
                return
            }
            // The suffix, not the whole token: enough to match this device against a line in the
            // relay's tokens.json (which logs the same suffix) without putting a full push
            // credential in the device log. Identifying which stored token belongs to which
            // handset was guesswork every time it mattered today.
            NSLog("NCDEBUG relay token registration succeeded (environment=%@, token ...%@)", environment, String(token.suffix(8)))
            registeredPushToStartToken = token
            Self.persistedLastRegisteredPushToStartToken = token

            // Best-effort cleanup of the token this device previously had registered — see
            // `persistedLastRegisteredPushToStartToken`'s doc for why leaving it registered
            // duplicates Live Activities. If this DELETE fails, the persisted value has already
            // moved on to `token`, so a future rotation retries against *that* token, not this
            // one — a delete failure here can leave one stale entry behind permanently rather
            // than compounding, with the relay's own APNs-410 cleanup as the remaining fallback.
            if let previousToken, previousToken != token {
                await deregisterPushToStartToken(previousToken, config: config)
            }
        } catch {
            NSLog("NCDEBUG relay token registration failed: %@", String(describing: error))
        }
    }

    /// DELETEs a push-to-start token this device no longer uses from the relay's `/register`
    /// endpoint, per its documented cleanup contract. Only ever called with a token this device
    /// itself previously registered and has since replaced — never a token another device owns.
    private func deregisterPushToStartToken(_ token: String, config: RelayConfigStore.Config) async {
        var request = URLRequest(url: config.url.appendingPathComponent("register"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(config.authSecret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["token": token])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            NSLog("NCDEBUG stale push-to-start token deregistration HTTP %d (token ...%@)", status, String(token.suffix(8)))
        } catch {
            NSLog("NCDEBUG stale push-to-start token deregistration failed: %@", String(describing: error))
        }
    }

    /// Registers every activity's own per-activity ActivityKit push token with the relay, so it
    /// can push `update`/`end` events directly to that activity via APNs, with no dependence on
    /// any local process being alive to find that activity first.
    ///
    /// An earlier version of this comment claimed a push-to-start-created activity could *never*
    /// be found locally via `Activity<PrintActivityAttributes>.activities` or `.activityUpdates`,
    /// citing both staying empty across an entire print. That observation was real but the
    /// explanation was wrong: push-to-start was silently broken at the time (the relay sent a
    /// module-qualified `attributes-type`), so no activity was ever created and there was nothing
    /// to discover. Confirmed 2026-09-07, with `attributes-type` fixed: `activityUpdates` below
    /// delivers the activity and this method registers its token ~3.5s after print start.
    ///
    /// The design is unchanged regardless — Apple's docs promise the system wakes the app
    /// specifically to deliver a fresh push token when it starts an activity via push-to-start,
    /// independent of the relay's own best-effort `content-available` wake, and `activityUpdates`
    /// is that channel.
    ///
    /// One task per printer's activity, not a single shared one: each activity has its own
    /// independent `pushTokenUpdates` stream and can rotate its token separately.
    ///
    /// Like `startObservingPushToStartTokenIfConfigured()`, call again after the relay config
    /// changes so a config saved after launch starts observing too — `activityDiscoveryTask`'s
    /// `== nil` guard means missing that call leaves activity discovery permanently dead for the
    /// rest of the process's life. Confirmed live: `RelayConnectionSheet.save()` re-armed only the
    /// push-to-start observer, not this one, so /register-activity never fired on any process
    /// whose first `configureFirebaseIfNeeded()` ran before the relay was configured.
    func startObservingActivityPushTokensIfConfigured() {
        guard activityDiscoveryTask == nil else { return }
        guard RelayConfigStore.isConfigured else {
            // Worth a line on its own: this is the state that used to be permanent for the life
            // of the process, and is now expected to clear on the next activation.
            NSLog("NCDEBUG activity discovery not started: relay config not readable yet")
            return
        }
        NSLog("NCDEBUG activity discovery starting")
        activityDiscoveryTask = Task {
            for await activity in Activity<PrintActivityAttributes>.activityUpdates {
                guard activityPushTokenTasks[activity.id] == nil else { continue }
                let printerID = activity.attributes.printerID
                NSLog("NCDEBUG activityUpdates discovered activity id=%@ printerID=%@", activity.id, printerID)
                // Register the token immediately if iOS has already generated it — pushTokenUpdates
                // may never fire if the activity ends before the async stream delivers its first value.
                if let tokenData = activity.pushToken {
                    NSLog("NCDEBUG activity push token immediately available for printerID=%@ (%d bytes)", printerID, tokenData.count)
                    await registerActivityPushToken(tokenData, printerID: printerID)
                }
                activityPushTokenTasks[activity.id] = Task {
                    for await tokenData in activity.pushTokenUpdates {
                        NSLog("NCDEBUG activity push token received for printerID=%@ (%d bytes)", printerID, tokenData.count)
                        await self.registerActivityPushToken(tokenData, printerID: printerID)
                    }
                    NSLog("NCDEBUG activity pushTokenUpdates stream ended for printerID=%@", printerID)
                }
            }
            // If this ever logs, the whole discovery mechanism is dead for the rest of the
            // process's life — `activityDiscoveryTask` stays non-nil, so the guard above never
            // lets it restart. `Activity<T>.activityUpdates` isn't documented to finish on its
            // own, but there's no other way here to tell "never started" apart from "started,
            // then silently died" without this.
            NSLog("NCDEBUG activityUpdates stream ended — activity discovery is now dead until relaunch")
        }
    }

    /// POSTs a single activity's push token to the relay's `/register-activity` endpoint, keyed by
    /// `printerID` (the same normalized key the NSE and app already match printers by) so the
    /// relay can look up which token to push `update`/`end` events to for a given Bambuddy event.
    private func registerActivityPushToken(_ tokenData: Data, printerID: String) async {
        guard let config = RelayConfigStore.load() else { return }
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        let environment = APNSEnvironment.current

        var request = URLRequest(url: config.url.appendingPathComponent("register-activity"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.authSecret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["token": token, "printerID": printerID, "environment": environment])

        NSLog("NCDEBUG activity push token registration POST to %@ for printerID=%@", config.url.appendingPathComponent("register-activity").absoluteString, printerID)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            NSLog("NCDEBUG activity push token registration HTTP %d for printerID=%@", status, printerID)
            guard (200..<300).contains(status) else {
                NSLog("NCDEBUG activity push token registration body: %@", String(data: data, encoding: .utf8) ?? "(non-UTF8)")
                return
            }
            NSLog("NCDEBUG activity push token registration succeeded for printerID=%@", printerID)
        } catch {
            NSLog("NCDEBUG activity push token registration failed: %@", String(describing: error))
        }
    }

    /// Scans all currently active Live Activities for an immediately-available push token and
    /// registers any found with the relay. Call after every background sync — `pushTokenUpdates`
    /// may not deliver while the app is suspended, so the token can arrive between wakeups without
    /// the async stream firing; this catches it via the synchronous `pushToken` property instead.
    /// - Returns: how many activities actually had a token to register on this pass. Zero means
    ///   there was nothing to hand the relay yet — either no activity exists (the wake can beat
    ///   push-to-start's own activity creation) or iOS hasn't generated its token — which is
    ///   precisely the case worth retrying, since the relay only sends this wake when it is
    ///   missing a token in the first place.
    /// Re-registers the push-to-start token with the relay, reading it synchronously rather than
    /// waiting on `pushToStartTokenUpdates` to yield.
    ///
    /// The async sequence fires when iOS issues or rotates a token — not on every launch, and not
    /// on demand. That left no recovery path from a state the relay can reach on its own: it
    /// *deletes* a push-to-start token on a 400/410 (`tokenStore.remove`), and once deleted, a
    /// token that never rotates again is never re-sent. The relay then has nothing to push
    /// push-to-start to, every subsequent print silently creates no Live Activity, and the only
    /// visible symptom is the app's own "open the app" fallback banner. Confirmed live
    /// 2026-09-08: an iPad and a phone on the same build and the same print, and only the iPad
    /// got a Live Activity — the iPad had been updated from TestFlight (a fresh install issues a
    /// fresh token, which fires the sequence and re-registers), the phone had not.
    ///
    /// Re-arming the observer does not help, and cannot: `pushToStartObservationTask` is already
    /// non-nil by then, so the guard returns immediately. Only reading the token directly does.
    ///
    /// `force` exists because local state cannot answer "does the relay still have this?" — the
    /// relay may have dropped a token this app still believes is registered, which is the exact
    /// failure being fixed. Background wakes pass `force: true` (they are rare — roughly one per
    /// print start — and are the self-healing path); activation passes `false` so returning from
    /// the app switcher doesn't POST every time.
    func recheckPushToStartToken(force: Bool = false) async {
        guard RelayConfigStore.isConfigured else { return }
        guard let tokenData = Activity<PrintActivityAttributes>.pushToStartToken else {
            NSLog("NCDEBUG recheckPushToStartToken: iOS has not issued a push-to-start token yet")
            return
        }
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        guard force || token != registeredPushToStartToken else { return }
        NSLog("NCDEBUG recheckPushToStartToken: registering ...%@ (force=%d, changed=%d)",
              String(token.suffix(8)), force, token != registeredPushToStartToken)
        await registerPushToStartToken(tokenData)
    }

    func recheckActivityTokens() async -> Int {
        guard RelayConfigStore.isConfigured else { return 0 }
        var registered = 0
        for activity in Activity<PrintActivityAttributes>.activities where activity.activityState == .active {
            guard let tokenData = activity.pushToken else { continue }
            let printerID = activity.attributes.printerID
            NSLog("NCDEBUG recheckActivityTokens: token available for printerID=%@ (%d bytes)", printerID, tokenData.count)
            await registerActivityPushToken(tokenData, printerID: printerID)
            registered += 1
        }
        return registered
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
        NSLog("NCDEBUG APNS device token received (%d bytes)", deviceToken.count)
        Messaging.messaging().apnsToken = deviceToken
        Task { await registerDeviceToken(deviceToken) }
    }

    /// POSTs the app's plain APNs device token (distinct from the ActivityKit push-to-start
    /// token registered above) to the relay's `/register-device` endpoint. The relay sends a
    /// silent `content-available` push to this token alongside every push-to-start request, so
    /// the app runs `PrintLiveActivityManager.sync` in the background — see that type's doc
    /// comment for why a push-to-start-created activity is otherwise invisible to the app, NSE,
    /// and widget extension until something runs that sync at least once.
    private func registerDeviceToken(_ deviceToken: Data) async {
        guard let config = RelayConfigStore.load() else {
            NSLog("NCDEBUG device token registration skipped: no relay configured")
            return
        }
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        let environment = APNSEnvironment.current

        var request = URLRequest(url: config.url.appendingPathComponent("register-device"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.authSecret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["token": token, "environment": environment])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                NSLog("NCDEBUG relay device token registration failed with unexpected response: %@", String(describing: response))
                return
            }
            NSLog("NCDEBUG relay device token registration succeeded (environment=%@)", environment)
        } catch {
            NSLog("NCDEBUG relay device token registration failed: %@", String(describing: error))
        }
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
    // Fires when Firebase finally has a valid FCM token — which may be later than the initial
    // `configureFirebaseIfNeeded()` call if the APNS token wasn't yet available (the most common
    // case on a cold launch: `registerForRemoteNotifications()` is async and `subscribe()` is
    // called before it completes, causing "No APNS token specified" and a failed subscription).
    // Re-subscribing here ensures the topic subscription actually lands even if the first attempt
    // was dropped.
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        // Firebase swizzles didRegisterForRemoteNotificationsWithDeviceToken and may not call
        // through to AppDelegate's implementation, so the APNS token never reaches handleAPNsToken
        // via that path. By the time this callback fires Firebase holds both the APNS and FCM
        // tokens, so grab the APNS token here as the guaranteed fallback.
        if let apnsToken = messaging.apnsToken {
            NSLog("NCDEBUG FCM callback: APNS token available (%d bytes), registering device with relay", apnsToken.count)
            Task { await registerDeviceToken(apnsToken) }
        } else {
            NSLog("NCDEBUG FCM callback: no APNS token available yet")
        }

        guard let config = PushSharedStore.loadNtfyConfig() else { return }
        NSLog("NCDEBUG FCM token received, re-subscribing to ntfy topic")
        subscribe(server: config.server, topic: config.topic, authToken: config.authToken)
    }
}
