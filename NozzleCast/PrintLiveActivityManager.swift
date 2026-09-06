@preconcurrency import ActivityKit
import Foundation
import UIKit
import UserNotifications
import NozzleCastShared

/// Keeps one Live Activity per actively-printing printer in sync with `AppStore`'s latest
/// refresh. There's no push channel driving most of this state between refreshes (Bambuddy's
/// server can't push directly to a Live Activity) — instead each update recomputes a start/end
/// date range consistent with the printer's current progress, and the widget's
/// `ProgressView(timerInterval:)` interpolates smoothly on-device until the next refresh
/// corrects it. The one field that IS pushed independently is `liveSnapshot`, updated directly
/// by the notification extension whenever Bambuddy's ntfy attachment carries a fresh camera
/// frame — this manager only ever supplies `coverImage` and leaves `liveSnapshot` untouched.
@Observable
final class PrintLiveActivityManager {
    static let shared = PrintLiveActivityManager()

    private init() {}

    /// The subset of a printer's state that actually changes what's on screen, keyed by
    /// `PrintActivityAttributes.printerID`. `ContentState.startedAt`/`estimatedEndAt` are
    /// re-derived from `Date()` on every call (see `contentState(for:...)`), so they drift by
    /// fractions of a second even when nothing real changed — comparing the full `ContentState`
    /// for equality would never skip a single update. Comparing this instead is what actually
    /// lets a no-op refresh skip the push, per Apple's "update only when new content is
    /// available" Live Activity guidance.
    private struct SyncFingerprint: Equatable {
        var progress: Double
        var stateLabel: String
        var jobName: String?
        var etaMinutesRemaining: Int?
        var currentLayer: Int?
        var totalLayers: Int?
        var nozzleTempC: Int?
        var bedTempC: Int?
        var issueSeverity: String?
        var issueCount: Int?
        var coverImage: Data?
        var liveSnapshot: Data?
    }

    private var lastFingerprints: [String: SyncFingerprint] = [:]

    /// Whether a printer's activity already has a cover image cached, so callers can skip
    /// re-fetching it (it's static for the whole print, unlike `liveSnapshot`).
    func hasCoverImage(printerName: String) -> Bool {
        Activity<PrintActivityAttributes>.activities
            .first { $0.activityState == .active && $0.attributes.printerID == PrintActivityAttributes.normalizedID(printerName) }?
            .content.state.coverImage != nil
    }

    /// Downscales a plate/cover render to a tiny JPEG for the Live Activity's content state.
    /// Sized to coexist with `liveSnapshot` in the same ~4KB budget (see `ContentState`'s note).
    /// The byte cap was originally tuned against a desktop JPEG encoder's output for a sample
    /// image and turned out to reject every real cover render on-device — `UIGraphicsImageRenderer`
    /// / `jpegData(compressionQuality:)` compress noticeably less efficiently than that encoder
    /// did for the same content, even at the lowest quality step. Confirmed empirically this time.
    nonisolated static func downscaledCoverImage(_ image: UIImage, maxDimension: CGFloat = 36, maxBytes: Int = 1000) -> Data? {
        let scale = min(maxDimension / max(image.size.width, image.size.height), 1)
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        // The real bug behind every "downscale still won't fit" symptom: UIGraphicsImageRenderer
        // defaults its render scale to the device's screen scale (2x/3x), so a "36pt" render was
        // actually rasterizing at up to 108x108 pixels — up to 9x the intended pixel count — no
        // matter how low the JPEG quality went. Pin scale to 1 so `targetSize` is the real pixel size.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        var quality: CGFloat = 0.5
        var jpeg = resized.jpegData(compressionQuality: quality)
        while let data = jpeg, data.count > maxBytes, quality > 0.1 {
            quality -= 0.1
            jpeg = resized.jpegData(compressionQuality: quality)
        }
        guard let jpeg, jpeg.count <= maxBytes else { return nil }
        return jpeg
    }

    /// Starts, updates, or ends activities to match the given printers. Call after every
    /// successful `AppStore.refresh()`. `coverImages` is a best-effort, pre-downscaled JPEG,
    /// keyed by `PrintActivityAttributes.normalizedID(printer.name)` (not `printer.id` — see
    /// that function's doc) — only needed for ones currently printing; nil entries just leave
    /// the activity's existing cover image as-is rather than clearing it, since it's fetched
    /// once at print start and doesn't change.
    func sync(printers: [Printer], coverImages: [String: Data] = [:]) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            NSLog("NCDEBUG sync skipped: areActivitiesEnabled=false")
            return
        }

        // Settings' "Live Activities" toggle — Apple's guidance says to make this easy to turn
        // off in-app rather than only through the system Settings app. This is the one path
        // guaranteed to run periodically (every foreground refresh), so it's what actually tears
        // down anything already running when someone flips the toggle off.
        guard PushSharedStore.liveActivitiesEnabled else {
            for activity in Activity<PrintActivityAttributes>.activities where activity.activityState == .active {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            lastFingerprints.removeAll()
            return
        }

        let printingByID = Dictionary(uniqueKeysWithValues: printers.filter { $0.state == .printing }.map { (PrintActivityAttributes.normalizedID($0.name), $0) })
        NSLog("NCDEBUG sync: printingCount=%d activeActivities=%d", printingByID.count, Activity<PrintActivityAttributes>.activities.filter { $0.activityState == .active }.count)

        // Awaited rather than fired as unstructured Tasks: an un-awaited `Task { await
        // activity.update(...) }` can get cut off before it completes if the app is backgrounded
        // right after this call returns — which is exactly the common case (open the app, glance
        // at it, lock the phone to check the Lock Screen) — silently dropping the update.
        // Only `.active` activities are touched or counted below — an already-ended one lingers
        // in `.activities` through its dismissal window (up to 30 minutes), and without this
        // filter a new print starting on the same printer within that window would be seen as
        // "already has an activity" and never get a fresh one.
        let activeActivities = Activity<PrintActivityAttributes>.activities.filter { $0.activityState == .active }

        for activity in activeActivities {
            guard let printer = printingByID[activity.attributes.printerID] else {
                await activity.end(nil, dismissalPolicy: .after(.now.addingTimeInterval(1800)))
                continue
            }
            let existing = activity.content.state
            let coverImage = coverImages[activity.attributes.printerID] ?? existing.coverImage
            let fingerprint = Self.fingerprint(for: printer, coverImage: coverImage, liveSnapshot: existing.liveSnapshot)
            // Apple's Live Activity guidance: "Update a Live Activity only when new content is
            // available." `ContentState.startedAt`/`estimatedEndAt` are re-derived from `Date()`
            // below on every call and drift by fractions of a second regardless, so comparing
            // those (or the whole `ContentState`) would never actually skip anything — this
            // fingerprint deliberately excludes them.
            guard lastFingerprints[activity.attributes.printerID] != fingerprint else { continue }
            lastFingerprints[activity.attributes.printerID] = fingerprint
            let state = Self.contentState(for: printer, coverImage: coverImage, liveSnapshot: existing.liveSnapshot)
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }

        lastFingerprints = lastFingerprints.filter { printingByID[$0.key] != nil }

        let activePrinterIDs = Set(activeActivities.map(\.attributes.printerID))
        let newPrinters = printingByID.values.filter { !activePrinterIDs.contains(PrintActivityAttributes.normalizedID($0.name)) }
        guard !newPrinters.isEmpty else { return }

        let appState = UIApplication.shared.applicationState

        // Activity.request() always throws a visibility error from the background — it can only
        // be called from the foreground. When backgrounded, rely on the push-to-start token that
        // was already registered with the relay, and prompt the user to foreground as a fallback.
        guard appState == .active || appState == .inactive else {
            NSLog("NCDEBUG sync: skipping Activity.request in background (state=%d), scheduling open-app prompt", appState.rawValue)
            await scheduleOpenAppNotification(for: newPrinters.map(\.name))
            return
        }

        NSLog("NCDEBUG sync: attempting Activity.request for %d printer(s) (state=%d)", newPrinters.count, appState.rawValue)
        for printer in newPrinters {
            let id = PrintActivityAttributes.normalizedID(printer.name)
            let attributes = PrintActivityAttributes(printerID: id, printerName: printer.name)
            let state = Self.contentState(for: printer, coverImage: coverImages[id], liveSnapshot: nil)
            lastFingerprints[id] = Self.fingerprint(for: printer, coverImage: coverImages[id], liveSnapshot: nil)
            do {
                // pushType: .token requests a per-activity push token for this activity, same as
                // one started via push-to-start gets automatically -- per Apple's docs, an
                // activity created without it never gets a push channel at all, regardless of any
                // later observation of `pushTokenUpdates`. This path only runs while the app is
                // foregrounded, but the relay (PushNotificationManager.startObservingActivityPushTokensIfConfigured)
                // is meant to drive every activity's update/end via APNs once backgrounded -- an
                // activity started here without this would have no push channel to fall back on.
                _ = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil), pushType: .token)
                NSLog("NCDEBUG Activity.request succeeded for printerID=%@", id)
            } catch {
                NSLog("NCDEBUG Activity.request failed for printerID=%@: %@", id, String(describing: error))
            }
        }
    }

    /// Posts a local notification when the app is in the background and can't create a Live
    /// Activity directly (ActivityKit's `.visibility` gate). The notification prompts the user to
    /// foreground the app so the next sync can call `Activity.request()` successfully.
    private func scheduleOpenAppNotification(for printerNames: [String]) async {
        let content = UNMutableNotificationContent()
        content.title = printerNames.count == 1
            ? "\(printerNames[0]) started printing"
            : "\(printerNames.count) printers started printing"
        content.body = "Open NozzleCast to start the Live Activity."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "com.victormanuel.NozzleCast.liveactivity-prompt",
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            NSLog("NCDEBUG scheduled open-app notification for %d printer(s)", printerNames.count)
        } catch {
            NSLog("NCDEBUG failed to schedule open-app notification: %@", String(describing: error))
        }
    }

    private static func issueInfo(for printer: Printer) -> (severity: String?, count: Int?) {
        let qualifyingSeverities = printer.hmsErrors.map(\.severity).filter { $0 <= 3 }
        guard !qualifyingSeverities.isEmpty else { return (nil, nil) }
        let severity = qualifyingSeverities.contains { $0 <= 2 } ? "error" : "warning"
        return (severity, qualifyingSeverities.count)
    }

    private static func fingerprint(for printer: Printer, coverImage: Data?, liveSnapshot: Data?) -> SyncFingerprint {
        let issue = issueInfo(for: printer)
        return SyncFingerprint(
            progress: printer.progress ?? 0,
            stateLabel: printer.state.label,
            jobName: printer.jobFileName,
            etaMinutesRemaining: printer.etaMinutesRemaining,
            currentLayer: printer.currentLayer,
            totalLayers: printer.totalLayers,
            nozzleTempC: printer.nozzle.current,
            bedTempC: printer.bed.current,
            issueSeverity: issue.severity,
            issueCount: issue.count,
            coverImage: coverImage,
            liveSnapshot: liveSnapshot
        )
    }

    private static func contentState(for printer: Printer, coverImage: Data?, liveSnapshot: Data?) -> PrintActivityAttributes.ContentState {
        let progress = printer.progress ?? 0
        let now = Date()
        let estimatedEnd = printer.etaMinutesRemaining.map { now.addingTimeInterval(TimeInterval($0 * 60)) }

        // Back-compute a start date consistent with the current progress, so the timer-driven
        // progress bar tracks the real percentage instead of restarting from 0 on every refresh.
        let startedAt: Date
        if let estimatedEnd, progress > 0, progress < 1 {
            let totalDuration = estimatedEnd.timeIntervalSince(now) / (1 - progress)
            startedAt = now.addingTimeInterval(-totalDuration * progress)
        } else {
            startedAt = now
        }

        let issue = issueInfo(for: printer)

        return .init(
            progress: progress,
            stateLabel: printer.state.label,
            jobName: printer.jobFileName,
            startedAt: startedAt,
            estimatedEndAt: estimatedEnd,
            currentLayer: printer.currentLayer,
            totalLayers: printer.totalLayers,
            nozzleTempC: printer.nozzle.current,
            bedTempC: printer.bed.current,
            coverImage: coverImage,
            liveSnapshot: liveSnapshot,
            issueSeverity: issue.severity,
            issueCount: issue.count
        )
    }
}
