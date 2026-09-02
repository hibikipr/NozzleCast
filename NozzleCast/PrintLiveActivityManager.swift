import ActivityKit
import Foundation
import UIKit

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
    func hasCoverImage(printerID: String) -> Bool {
        Activity<PrintActivityAttributes>.activities
            .first { $0.attributes.printerID == printerID }?
            .content.state.coverImage != nil
    }

    /// Downscales a plate/cover render to a tiny JPEG for the Live Activity's content state.
    /// Sized to coexist with `liveSnapshot` in the same ~4KB budget (see `ContentState`'s note).
    static func downscaledCoverImage(_ image: UIImage, maxDimension: CGFloat = 40, maxBytes: Int = 700) -> Data? {
        let scale = min(maxDimension / max(image.size.width, image.size.height), 1)
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: targetSize).image { _ in
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
    /// successful `AppStore.refresh()`. `coverImages` is a best-effort, pre-downscaled JPEG per
    /// printer (only needed for ones currently printing) — nil entries just leave the activity's
    /// existing cover image as-is rather than clearing it, since it's fetched once at print
    /// start and doesn't change.
    func sync(printers: [Printer], coverImages: [String: Data] = [:]) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let printingByID = Dictionary(uniqueKeysWithValues: printers.filter { $0.state == .printing }.map { ($0.id, $0) })

        // Awaited rather than fired as unstructured Tasks: an un-awaited `Task { await
        // activity.update(...) }` can get cut off before it completes if the app is backgrounded
        // right after this call returns — which is exactly the common case (open the app, glance
        // at it, lock the phone to check the Lock Screen) — silently dropping the update.
        for activity in Activity<PrintActivityAttributes>.activities {
            guard let printer = printingByID[activity.attributes.printerID] else {
                await activity.end(nil, dismissalPolicy: .after(.now.addingTimeInterval(30)))
                continue
            }
            let existing = activity.content.state
            let state = Self.contentState(
                for: printer,
                coverImage: coverImages[printer.id] ?? existing.coverImage,
                liveSnapshot: existing.liveSnapshot
            )
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }

        let activePrinterIDs = Set(Activity<PrintActivityAttributes>.activities.map(\.attributes.printerID))
        for printer in printingByID.values where !activePrinterIDs.contains(printer.id) {
            let attributes = PrintActivityAttributes(printerID: printer.id, printerName: printer.name)
            let state = Self.contentState(for: printer, coverImage: coverImages[printer.id], liveSnapshot: nil)
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
            liveSnapshot: liveSnapshot
        )
    }
}
