import ActivityKit
import BackgroundTasks
import UIKit
import UserNotifications
import FirebaseMessaging
import NozzleCastShared

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Owned here, not as a SwiftUI `@State` in `MyApp`: `UIApplicationDelegateAdaptor` guarantees
    /// this delegate (and therefore this property) exists before any `Scene` is created, which is
    /// the only launch-time guarantee that survives a headless background launch — e.g. one woken
    /// solely by the relay's silent `content-available` push while the phone is locked and the app
    /// isn't already running. A `WindowGroup`'s `@State` has no such guarantee; relying on it here
    /// meant `didReceiveRemoteNotification` could find no store to refresh on exactly the launches
    /// this whole push-to-start path exists for.
    ///
    /// Initialized with `autoConnect: false` so headless background wakes don't fire a full
    /// `testConnectionAndRefresh()` alongside `refreshForBackgroundWake()`. Normal foreground
    /// launches start initial connection in `didFinishLaunchingWithOptions` / `appDidBecomeActive`.
    let store = AppStore(config: BambuddyConfig(), autoConnect: false)
    private var hasStartedInitialConnection = false

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PushNotificationManager.shared.configureFirebaseIfNeeded()
        // Separate call, and deliberately not inside configureFirebaseIfNeeded(): ActivityKit
        // token observation has nothing to do with Firebase, and living behind that method's
        // early-return guards meant it silently never started when no Firebase config file had
        // been imported — leaving a fully-configured relay with no push-to-start token to push to.
        PushNotificationManager.shared.startObservingActivityKitTokens()
        UNUserNotificationCenter.current().delegate = self
        // A scene-based app (every SwiftUI app) never gets UIApplicationDelegate's
        // applicationDidBecomeActive: iOS sends scene callbacks instead. It still posts this
        // notification, so the activation work hangs off it.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appDidBecomeActive() }
        }

        let launchedInBackground = application.applicationState == .background
        if !launchedInBackground, store.config.isConfigured {
            hasStartedInitialConnection = true
            Task { await store.testConnectionAndRefresh() }
        }

        // Must be registered before launch finishes. Runs a full printer refresh, which also checks for
        // alerts (the relay's feed or Bambuddy's notification log; see BambuddyAlertFeed) and rewrites
        // the widget snapshots, so Home Screen widgets stay current while the app is closed.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BambuddyAlertFeed.backgroundTaskIdentifier, using: nil) { [store] task in
            Task { @MainActor in
                BambuddyAlertFeed.scheduleBackgroundCheck()
                let work = Task {
                    let before = store.lastSuccessfulRefreshAt
                    await store.refresh()
                    guard !Task.isCancelled else { return }
                    // A refresh checks alerts only when it succeeds; if it didn't, still check them.
                    if store.lastSuccessfulRefreshAt == before { _ = await store.checkBambuddyAlerts() }
                }
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
    ///
    /// This used to be `applicationDidBecomeActive`, which a scene-based app never receives, so
    /// none of it ran: the extension never got the relay's address (`saveRelayConnection`), so
    /// alert photos kept on the relay were never fetched.
    private func appDidBecomeActive() {
        store.config.reloadIfStorageWasUnavailable()
        if !hasStartedInitialConnection, store.config.isConfigured {
            hasStartedInitialConnection = true
            if case .connected = store.connectionStatus {} else {
                Task { await store.testConnectionAndRefresh() }
            }
        }
        // Foreground means unlocked, so the relay config is readable — mirror whether it exists
        // for the notification extension, which can't read the app's own container.
        PushSharedStore.relayConfigured = RelayConfigStore.isConfigured
        // For installs whose relay was set up before the extension needed its address.
        do {
            try PushSharedStore.saveRelayConnection(RelayConfigStore.load().map { .init(url: $0.url, authSecret: $0.authSecret) })
        } catch {
            NSLog("NCDEBUG couldn't save the relay address for the notification extension: %@", String(describing: error))
        }
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
        let coordinator = WakeTaskCoordinator()
        coordinator.deadlineTask = Task {
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled else { return }
            coordinator.syncTask?.cancel()
            if completion.finish(.failed) {
                NSLog("NCDEBUG AppDelegate background sync hit its 25s deadline, completing early")
            }
        }

        coordinator.syncTask = Task {
            defer { coordinator.deadlineTask?.cancel() }

            // Run token registration checks in parallel with the lightweight background refresh so
            // token registration is never starved behind a slow cover fetch.
            async let pushToStartRecheck: Void = PushNotificationManager.shared.recheckPushToStartToken(force: true)
            async let initialActivityTokens = PushNotificationManager.shared.recheckActivityTokens()
            async let backgroundRefresh: Void = store.refreshForBackgroundWake()

            _ = await pushToStartRecheck
            _ = await initialActivityTokens
            await backgroundRefresh
            guard !Task.isCancelled else { return }
            NSLog("NCDEBUG AppDelegate background sync complete (printingCount=%d)", store.printers.filter { $0.state == .printing }.count)

            // pushTokenUpdates may not fire while the app is suspended — poll the synchronous
            // pushToken property on every wakeup so we catch the token as soon as iOS generates it.
            //
            // Retry only when an active print still needs a per-activity token (i.e. not already
            // registered and not subscribed via a broadcast channel), and without re-running a
            // full store refresh on each retry.
            for attempt in 1...2 {
                guard !Task.isCancelled else { return }
                let shouldRetry = await needsActivityTokenRetry(
                    printers: store.printers,
                    didRefresh: store.lastSuccessfulRefreshAt != nil
                )
                guard shouldRetry else { break }
                guard Date().timeIntervalSince(wakeStartedAt) < 12 else {
                    NSLog("NCDEBUG AppDelegate skipping token recheck retry %d: not enough background time left", attempt)
                    break
                }
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                let registered = await PushNotificationManager.shared.recheckActivityTokens()
                NSLog("NCDEBUG AppDelegate token recheck retry %d (registered=%d)", attempt, registered)
            }
            if !Task.isCancelled {
                completion.finish(.newData)
            }
        }
    }

    private func needsActivityTokenRetry(printers: [Printer], didRefresh: Bool) async -> Bool {
        let activeActivities = Activity<PrintActivityAttributes>.activities.filter { $0.activityState == .active }
        let activityByPrinterID = Dictionary(activeActivities.map { ($0.attributes.printerID, $0) }, uniquingKeysWith: { first, _ in first })
        let printingPrinterIDs = Set(printers.filter { $0.state == .printing }.map { PrintActivityAttributes.normalizedID($0.name) })

        var printerIDsNeedingTokenCheck: [String] = []
        if !printingPrinterIDs.isEmpty {
            for id in printingPrinterIDs {
                if let activity = activityByPrinterID[id] {
                    if activity.pushToken == nil {
                        printerIDsNeedingTokenCheck.append(id)
                    }
                } else {
                    printerIDsNeedingTokenCheck.append(id)
                }
            }
        } else if !didRefresh {
            for activity in activeActivities where activity.pushToken == nil {
                printerIDsNeedingTokenCheck.append(activity.attributes.printerID)
            }
        }

        guard !printerIDsNeedingTokenCheck.isEmpty else { return false }
        guard RelayConfigStore.isConfigured else { return true }

        return await withTaskGroup(of: Bool.self) { group in
            for id in printerIDsNeedingTokenCheck {
                group.addTask {
                    await PushNotificationManager.shared.broadcastChannelID(printerID: id) == nil
                }
            }
            for await lacksChannel in group where lacksChannel {
                group.cancelAll()
                return true
            }
            return false
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

@MainActor
private final class WakeTaskCoordinator {
    var syncTask: Task<Void, Never>?
    var deadlineTask: Task<Void, Never>?
}
