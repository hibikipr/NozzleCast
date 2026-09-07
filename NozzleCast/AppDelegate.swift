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
        Messaging.messaging().appDidReceiveMessage(userInfo)
        Task {
            await store.refresh()
            var printingCount = store.printers.filter { $0.state == .printing }.count
            NSLog("NCDEBUG AppDelegate background sync complete (printingCount=%d)", printingCount)

            // Bambuddy's REST API lags 5-10s behind the print-start event that triggered
            // this push. Retry twice so the Bambuddy API has time to catch up before we
            // give up and leave the push-to-start activity without a registered token.
            for attempt in 1...2 where printingCount == 0 {
                try? await Task.sleep(for: .seconds(5))
                await store.refresh()
                printingCount = store.printers.filter { $0.state == .printing }.count
                NSLog("NCDEBUG AppDelegate background sync retry %d (printingCount=%d)", attempt, printingCount)
            }
            // pushTokenUpdates may not fire while the app is suspended — poll the synchronous
            // pushToken property on every wakeup so we catch the token as soon as iOS generates it.
            await PushNotificationManager.shared.recheckActivityTokens()
            completionHandler(.newData)
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
