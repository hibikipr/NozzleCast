import BackgroundTasks
import UIKit
import UserNotifications
import FirebaseMessaging

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Owned here, not as a SwiftUI `@State` in `MyApp`: `UIApplicationDelegateAdaptor` guarantees
    /// this delegate (and therefore this property) exists before any `Scene` is created, which is
    /// the only launch-time guarantee that survives a headless background launch — e.g. one woken
    /// solely by the relay's silent `content-available` push while the phone is locked and the app
    /// isn't already running. A `WindowGroup`'s `@State` has no such guarantee; relying on it here
    /// meant `didReceiveRemoteNotification` could find no store to refresh on exactly the launches
    /// this whole push-to-start path exists for.
    let store = AppStore(config: BambuddyConfig())

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PushNotificationManager.shared.configureFirebaseIfNeeded()
        // Separate call, and deliberately not inside configureFirebaseIfNeeded(): ActivityKit
        // token observation has nothing to do with Firebase, and living behind that method's
        // early-return guards meant it silently never started when no Firebase config file had
        // been imported — leaving a fully-configured relay with no push-to-start token to push to.
        PushNotificationManager.shared.startObservingActivityKitTokens()
        UNUserNotificationCenter.current().delegate = self

        // Must be registered before launch finishes. Checks Bambuddy's notification log when no
        // Firebase config delivers alerts as pushes — see BambuddyAlertFeed.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BambuddyAlertFeed.backgroundTaskIdentifier, using: nil) { [store] task in
            Task { @MainActor in
                BambuddyAlertFeed.scheduleBackgroundCheck()
                let work = Task { _ = await store.checkBambuddyAlerts() }
                task.expirationHandler = { work.cancel() }
                await work.value
                task.setTaskCompleted(success: !work.isCancelled)
            }
        }
        BambuddyAlertFeed.scheduleBackgroundCheck()

        // Re-registering on every launch (not just the one time the user tapped "enable" in
        // Settings) keeps the plain APNs device token the relay uses for its `content-available`
        // wake push fresh — `didRegisterForRemoteNotificationsWithDeviceToken` fires again even
        // when the token hasn't changed, but skipping this call on ordinary relaunches meant a
        // rotated token would silently stop the relay's wake push from ever reaching this device.
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            NSLog("NCDEBUG launch notification authorizationStatus=%ld", settings.authorizationStatus.rawValue)
            if settings.authorizationStatus == .authorized {
                await MainActor.run { application.registerForRemoteNotifications() }
            } else {
                // Silent before this: if permission was ever revoked (or never granted) after an
                // earlier launch, this branch skips `registerForRemoteNotifications()` every time
                // — the plain APNs device token `/register-device` needs never gets requested
                // again, with nothing in the logs showing why. Distinct from Live Activities
                // itself, which has its own separate iOS permission and keeps working regardless.
                NSLog("NCDEBUG skipping registerForRemoteNotifications: not authorized")
            }
        }
        return true
    }

    /// Re-arms everything that can silently fail to start when the device is locked at launch.
    ///
    /// `didFinishLaunching` is not a safe place to do this once and be done: a launch before the
    /// device's first unlock since boot — a background push wake right after a restart — cannot
    /// read `RelayConfigStore`'s file (Application Support is protected until first unlock) or the
    /// Keychain, so `startObservingActivityKitTokens()` sees `isConfigured == false` and quietly
    /// arms neither token observer. The only other caller was `RelayConnectionSheet.save()`, so
    /// for the rest of that process's life no push-to-start token was ever observed and no
    /// activity token was ever registered — the relay went on pushing to a stale token, got a
    /// genuine 200 for it, and no Live Activity was ever created.
    ///
    /// Being foreground means the device is unlocked, so this is the one moment both stores are
    /// guaranteed readable. Both callees guard on their own already-running check, so re-arming
    /// on every activation is idempotent.
    func applicationDidBecomeActive(_ application: UIApplication) {
        store.config.reloadIfStorageWasUnavailable()
        // Foreground means unlocked, so the relay config is readable — mirror whether it exists
        // for the notification extension, which can't read the app's own container.
        PushSharedStore.relayConfigured = RelayConfigStore.isConfigured
        PushNotificationManager.shared.startObservingActivityKitTokens()
        // Not forced: this runs on every return from the app switcher, and a POST each time would
        // be noise. A token that actually changed still re-registers here immediately.
        Task { await PushNotificationManager.shared.recheckPushToStartToken() }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushNotificationManager.shared.handleAPNsToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No user-facing surface for this — push simply stays unavailable until the next
        // successful registration attempt (e.g. after the user re-grants permission). Previously
        // had no logging at all, so this failure path was completely invisible — if
        // `registerForRemoteNotifications()` fails, `handleAPNsToken`/`/register-device` never
        // fires and there was no trace of why.
        NSLog("NCDEBUG registerForRemoteNotifications failed: %@", String(describing: error))
    }

    /// Handles the relay's `content-available` background wake push (see
    /// `PushNotificationManager.registerDeviceToken` and `nozzlecast-relay`'s `/register-device`)
    /// by running the same sync a manual foreground does. This is the only thing that populates
    /// `Activity<PrintActivityAttributes>.activities` for a push-to-start-created activity in any
    /// process — without it, the Live Activity appears on a locked phone but never updates until
    /// the user happens to open the app themselves.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        NSLog("NCDEBUG AppDelegate received remote notification, waking store to sync")
        // Required when FirebaseAppDelegateProxyEnabled = false — Firebase won't see FCM messages
        // otherwise, and the ntfy topic subscription (routed via FCM) would stop delivering.
        // Only with Firebase configured: Messaging traps otherwise, and the relay's wake push
        // reaches installs without one too.
        if PushNotificationManager.shared.isFirebaseConfigured { Messaging.messaging().appDidReceiveMessage(userInfo) }
        // Cheap, and the wake may be the first run since the device was unlocked — if launch
        // happened while locked, this is the earliest chance to arm the observers that silently
        // didn't start then. A no-op when they are already running or the device is still locked.
        store.config.reloadIfStorageWasUnavailable()
        PushNotificationManager.shared.startObservingActivityKitTokens()

        // iOS allows roughly 30s for this handler; overrunning it gets the app killed and makes
        // the system ration future background wakes more tightly — exactly the wakes the relay
        // relies on to collect activity tokens. Every step below is network-bound (a refresh is
        // several dependent rounds of requests), so the work is raced against a hard deadline and
        // the completion handler is called exactly once, whichever finishes first. Retries are
        // only started while there is clearly time left for one to finish.
        let wakeStartedAt = Date()
        let completion = BackgroundFetchCompletion(completionHandler)
        Task {
            try? await Task.sleep(for: .seconds(25))
            if completion.finish(.failed) {
                NSLog("NCDEBUG AppDelegate background sync hit its 25s deadline, completing early")
            }
        }

        Task {
            await store.refresh()
            NSLog("NCDEBUG AppDelegate background sync complete (printingCount=%d)", store.printers.filter { $0.state == .printing }.count)

            // pushTokenUpdates may not fire while the app is suspended — poll the synchronous
            // pushToken property on every wakeup so we catch the token as soon as iOS generates it.
            //
            // The retry condition is the token, not the printer count. It used to retry while
            // `printingCount == 0`, on the reasoning that Bambuddy's REST API lags 5-10s behind
            // the print-start event that triggered this push — but printer state was never what
            // this wake needs. Registering the activity's push token is, and the two come apart
            // in both directions: with another printer already mid-print the count is non-zero
            // immediately, so the loop was skipped and the token could be missed; and a non-zero
            // count says nothing about whether iOS has generated a token yet. Retrying on the
            // token itself also covers the wake arriving before push-to-start has created the
            // activity at all, which the old condition could not see.
            // Forced, unlike the activation path: the relay deletes a push-to-start token on a
            // 400/410, and nothing local can tell that happened -- the app still believes its
            // token is registered. A wake is rare (roughly one per print start) and is the one
            // moment worth spending a POST to re-assert it, so a dropped token heals by the next
            // print instead of never. See recheckPushToStartToken.
            await PushNotificationManager.shared.recheckPushToStartToken(force: true)

            var registered = await PushNotificationManager.shared.recheckActivityTokens()
            for attempt in 1...2 where registered == 0 {
                guard Date().timeIntervalSince(wakeStartedAt) < 12 else {
                    NSLog("NCDEBUG AppDelegate skipping token recheck retry %d: not enough background time left", attempt)
                    break
                }
                try? await Task.sleep(for: .seconds(5))
                await store.refresh()
                registered = await PushNotificationManager.shared.recheckActivityTokens()
                NSLog("NCDEBUG AppDelegate token recheck retry %d (registered=%d)", attempt, registered)
            }
            completion.finish(.newData)
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Show banners even while the app is foregrounded, since these are time-sensitive printer
    /// alerts the user would otherwise miss until they background/reopen the app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

/// Calls a background-fetch completion handler at most once, for the deadline race in
/// `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)` — calling it twice is a
/// programming error UIKit reports, and not calling it at all costs future background time.
@MainActor
private final class BackgroundFetchCompletion {
    private var handler: ((UIBackgroundFetchResult) -> Void)?

    init(_ handler: @escaping (UIBackgroundFetchResult) -> Void) {
        self.handler = handler
    }

    /// Returns whether this call was the one that completed.
    @discardableResult
    func finish(_ result: UIBackgroundFetchResult) -> Bool {
        guard let handler else { return false }
        self.handler = nil
        handler(result)
        return true
    }
}
