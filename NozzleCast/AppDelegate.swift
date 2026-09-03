import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PushNotificationManager.shared.configureFirebaseIfNeeded()
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushNotificationManager.shared.handleAPNsToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No user-facing surface for this — push simply stays unavailable until the next
        // successful registration attempt (e.g. after the user re-grants permission).
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
        guard let store = AppStore.shared else {
            completionHandler(.noData)
            return
        }
        Task {
            await store.refresh()
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
