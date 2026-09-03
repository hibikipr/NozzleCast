import ActivityKit
import Foundation
import UIKit
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
    static func downscaledCoverImage(_ image: UIImage, maxDimension: CGFloat = 36, maxBytes: Int = 1000) -> Data? {
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
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let printingByID = Dictionary(uniqueKeysWithValues: printers.filter { $0.state == .printing }.map { (PrintActivityAttributes.normalizedID($0.name), $0) })

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
                await activity.end(nil, dismissalPolicy: .after(.now.addingTimeInterval(30)))
                continue
            }
            let existing = activity.content.state
            let state = Self.contentState(
                for: printer,
                coverImage: coverImages[activity.attributes.printerID] ?? existing.coverImage,
                liveSnapshot: existing.liveSnapshot
            )
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }

        let activePrinterIDs = Set(activeActivities.map(\.attributes.printerID))
        for printer in printingByID.values where !activePrinterIDs.contains(PrintActivityAttributes.normalizedID(printer.name)) {
            let id = PrintActivityAttributes.normalizedID(printer.name)
            let attributes = PrintActivityAttributes(printerID: id, printerName: printer.name)
            let state = Self.contentState(for: printer, coverImage: coverImages[id], liveSnapshot: nil)
            _ = try? Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil))
        }
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

        let qualifyingSeverities = printer.hmsErrors.map(\.severity).filter { $0 <= 3 }
        let issueSeverity: String? = qualifyingSeverities.isEmpty ? nil : (qualifyingSeverities.contains { $0 <= 2 } ? "error" : "warning")

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
            issueSeverity: issueSeverity,
            issueCount: qualifyingSeverities.isEmpty ? nil : qualifyingSeverities.count
        )
    }
}
