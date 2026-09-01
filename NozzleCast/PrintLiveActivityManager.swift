import ActivityKit
import Foundation

/// Keeps one Live Activity per actively-printing printer in sync with `AppStore`'s latest
/// refresh. There's no push channel driving updates between refreshes (Bambuddy's server can't
/// push directly to a Live Activity) — instead each update recomputes a start/end date range
/// consistent with the printer's current progress, and the widget's `ProgressView(timerInterval:)`
/// interpolates smoothly on-device until the next refresh corrects it.
@Observable
final class PrintLiveActivityManager {
    static let shared = PrintLiveActivityManager()

    private init() {}

    /// Starts, updates, or ends activities to match the given printers. Call after every
    /// successful `AppStore.refresh()`. `coverThumbnails` is a best-effort, pre-downscaled JPEG
    /// per printer (only needed for ones currently printing) — nil entries just leave the
    /// activity's existing thumbnail as-is rather than clearing it.
    func sync(printers: [Printer], coverThumbnails: [String: Data] = [:]) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let printingByID = Dictionary(uniqueKeysWithValues: printers.filter { $0.state == .printing }.map { ($0.id, $0) })

        for activity in Activity<PrintActivityAttributes>.activities {
            guard let printer = printingByID[activity.attributes.printerID] else {
                Task { await activity.end(nil, dismissalPolicy: .after(.now.addingTimeInterval(30))) }
                continue
            }
            let existingThumbnail = activity.content.state.coverThumbnail
            let state = Self.contentState(for: printer, coverThumbnail: coverThumbnails[printer.id] ?? existingThumbnail)
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
        }

        let activePrinterIDs = Set(Activity<PrintActivityAttributes>.activities.map(\.attributes.printerID))
        for printer in printingByID.values where !activePrinterIDs.contains(printer.id) {
            let attributes = PrintActivityAttributes(printerID: printer.id, printerName: printer.name)
            let state = Self.contentState(for: printer, coverThumbnail: coverThumbnails[printer.id])
            _ = try? Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil))
        }
    }

    private static func contentState(for printer: Printer, coverThumbnail: Data?) -> PrintActivityAttributes.ContentState {
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
            coverThumbnail: coverThumbnail
        )
    }
}
