@preconcurrency import ActivityKit
import Foundation
import UIKit
import UserNotifications
import NozzleCastShared
import ActivityTeardownPolicy

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
        var rightNozzleTempC: Int?
        var bedTempC: Int?
        var issueSeverity: String?
        var issueCount: Int?
        var stageDetail: String?
        var coverImage: Data?
        var liveSnapshot: Data?
    }

    private var lastFingerprints: [String: SyncFingerprint] = [:]

    /// Per printer, when it was first seen in a confirmed-terminal state while its Live Activity
    /// was still live — the clock `ActivityTeardown` measures its grace window against. See that
    /// type for why teardown hangs off a positive "this job is over" signal rather than off the
    /// absence of a "still printing" one. In-memory only: losing it on relaunch just restarts the
    /// window, which errs toward keeping an activity alive, the safe direction.
    private var teardownAnchors: [String: Date] = [:]

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
            teardownAnchors.removeAll()
            return
        }

        // Keyed by the same normalized id the relay uses, so an activity it created is matched
        // here. Every printer, not just the printing ones: a printer's *absence* from this map is
        // itself meaningful ("no reading"), and must not be confused with "reports no job".
        // `uniquingKeysWith`, not `uniqueKeysWithValues`: normalizedID is lossy (it strips
        // everything but letters/digits), so two printers named "Vic H2C" and "vic-h2c" collide —
        // and the trapping initializer would crash the app on a refresh rather than just picking
        // one. Previously this only mapped the printing subset, where a collision was unlikely;
        // over every printer it is a real possibility worth failing soft on.
        let byID = Dictionary(printers.map { (PrintActivityAttributes.normalizedID($0.name), $0) }, uniquingKeysWith: { first, _ in first })
        // Only genuinely-printing printers get an activity *created* locally — unchanged. Keeping
        // an existing one alive is a separate, broader question answered by `jobPhase` below.
        let printingByID = byID.filter { $0.value.state == .printing }
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

        let now = Date()
        for activity in activeActivities {
            let id = activity.attributes.printerID
            let printer = byID[id]

            // The relay owns ending this activity (it pushes `end` on finish/stopped/failed);
            // this is only the backstop for a relay that never does. Previously this line ended
            // any activity whose printer wasn't reporting `.printing` at that instant, which
            // meant Bambuddy's 5-10s REST lag right after push-to-start, a pause, a mid-print HMS
            // warning, or one failed /status fetch each killed a live print's activity outright —
            // and because it ended with a 30-minute dismissal window rather than immediately, the
            // result looked exactly like an activity that had simply stopped updating.
            let decision = ActivityTeardown.evaluate(isActiveJob: printer?.jobPhase?.isActive, anchor: teardownAnchors[id], now: now)
            teardownAnchors[id] = decision.anchor
            if decision.shouldEnd {
                NSLog("NCDEBUG sync: ending activity for printerID=%@ (Bambuddy confirmed no job for the full grace window)", id)
                await activity.end(nil, dismissalPolicy: .after(.now.addingTimeInterval(1800)))
                continue
            }

            // The relay owns this activity's content whenever one is configured, and this is the
            // only place the app would otherwise write to it.
            //
            // Both sides recompute the *entire* content state from the same Bambuddy API, so the
            // app adds nothing the relay does not already have — but it derived some of it less
            // carefully, and ActivityKit replaces content wholesale, so whichever wrote last won.
            // Foregrounding the app during the window where Bambuddy has not yet computed a real
            // remaining_time overwrote the relay's correctly-omitted estimate with a wrong one;
            // the same shape applied to the issue badge and the state label. Making two writers
            // agree on every field is a losing game, so there is one writer instead.
            //
            // With no relay configured the app is the sole writer and still updates normally —
            // its own derivations are aligned with the relay's for exactly that path (see
            // `RemainingTimeTrust`, `JobPhase.liveActivityLabel`).
            guard !RelayConfigStore.isConfigured else { continue }
            guard let printer, printer.jobPhase?.isActive == true else { continue }
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
            // `startedAt: existing.startedAt` — the app must not recompute this for an activity
            // that already has one. Two writers drive this activity: the relay, which tracks the
            // print's real start time in `activity-tokens.json` and sends it on every push, and
            // this method, which back-computes a start from progress + ETA. The relay's value is
            // the true one and is stable for the whole print; the local back-computation lands
            // somewhere different on every single sync (which is exactly why `SyncFingerprint`
            // has to exclude it — otherwise no refresh would ever be skippable). Overwriting a
            // pushed value with the derived one made the widget's elapsed-time math jump every
            // time the app happened to refresh. A print's start time doesn't change; nothing here
            // has any business restating it.
            let state = Self.contentState(for: printer, coverImage: coverImage, liveSnapshot: existing.liveSnapshot, startedAt: existing.startedAt)
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }

        let activePrinterIDs = Set(activeActivities.map(\.attributes.printerID))
        // Pruned against activities that still exist, not against "is printing" — a paused print
        // keeps both its activity and the state we track for it.
        lastFingerprints = lastFingerprints.filter { activePrinterIDs.contains($0.key) }
        teardownAnchors = teardownAnchors.filter { activePrinterIDs.contains($0.key) }

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
                // drives every activity's update/end via APNs once backgrounded -- an activity
                // started here without this would have no push channel to fall back on.
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
            rightNozzleTempC: printer.rightNozzle?.current,
            bedTempC: printer.bed.current,
            issueSeverity: issue.severity,
            issueCount: issue.count,
            stageDetail: printer.stageDetail,
            coverImage: coverImage,
            liveSnapshot: liveSnapshot
        )
    }

    /// `startedAt`, when non-nil, is the activity's existing start date and is used verbatim.
    /// Only a brand-new activity (which has none yet) gets the back-computed fallback below.
    private static func contentState(for printer: Printer, coverImage: Data?, liveSnapshot: Data?, startedAt existingStartedAt: Date? = nil) -> PrintActivityAttributes.ContentState {
        let progress = printer.progress ?? 0
        let now = Date()
        let estimatedEnd = printer.etaMinutesRemaining.map { now.addingTimeInterval(TimeInterval($0 * 60)) }

        // Back-compute a start date consistent with the current progress, so the timer-driven
        // progress bar tracks the real percentage instead of restarting from 0. Only ever used
        // when creating an activity locally -- an existing one already carries a start date, from
        // the relay or from this same fallback at creation, and it must not be restated.
        let startedAt: Date
        if let existingStartedAt {
            startedAt = existingStartedAt
        } else if let estimatedEnd, progress > 0, progress < 1 {
            let totalDuration = estimatedEnd.timeIntervalSince(now) / (1 - progress)
            startedAt = now.addingTimeInterval(-totalDuration * progress)
        } else {
            startedAt = now
        }

        let issue = issueInfo(for: printer)

        return .init(
            progress: progress,
            // The job phase, not `state.label`: `mapState` collapses a qualifying HMS issue into
            // `.error` before it looks at the gcode state, so a print with a warning attached
            // would announce itself as "Error" while the relay calls the same print "Printing"
            // and puts the issue on the badge. The badge is where an issue belongs; the label
            // says what the printer is doing. Falls back for a printer with no usable reading.
            stateLabel: printer.jobPhase?.liveActivityLabel ?? printer.state.label,
            jobName: printer.jobFileName,
            startedAt: startedAt,
            estimatedEndAt: estimatedEnd,
            currentLayer: printer.currentLayer,
            totalLayers: printer.totalLayers,
            nozzleTempC: printer.nozzle.current,
            rightNozzleTempC: printer.rightNozzle?.current,
            bedTempC: printer.bed.current,
            coverImage: coverImage,
            liveSnapshot: liveSnapshot,
            issueSeverity: issue.severity,
            issueCount: issue.count,
            stageDetail: printer.stageDetail
        )
    }
}
