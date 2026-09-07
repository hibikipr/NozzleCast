import ActivityKit
import Foundation

/// Shared via the local `NozzleCastShared` package rather than duplicated per target: ActivityKit
/// identifies an `ActivityAttributes` type by its module-qualified name, so a structurally
/// identical `PrintActivityAttributes` compiled separately into each target's own module (the
/// previous approach) is a *different* type as far as `Activity<PrintActivityAttributes>.activities`
/// is concerned — an activity started by one target is invisible to another. All three targets
/// (app, NSE, widget extension) must depend on this one compiled definition.
public struct PrintActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var progress: Double
        public var stateLabel: String
        public var jobName: String?
        /// A date range consistent with the printer's current progress, used to drive a
        /// `ProgressView(timerInterval:)` that animates smoothly on-device between refreshes
        /// without needing a push for every tick.
        public var startedAt: Date
        public var estimatedEndAt: Date?

        public var currentLayer: Int?
        public var totalLayers: Int?
        public var nozzleTempC: Int?
        public var bedTempC: Int?

        /// Bambuddy's own HMS severity scale collapsed to two tiers for the badge: "error"
        /// (severity 1-2, Bambuddy's Fatal/Serious) or "warning" (severity 3, Bambuddy's own
        /// "Warning" label) — nil when there's no qualifying issue. Severity 4/Info (Bambuddy's
        /// own default case) is deliberately excluded here, not just at nil-count: confirmed live
        /// that a routine "Developer Mode not enabled" advisory is genuine severity 5, and Bambuddy's
        /// own UI colors that blue/informational, never as a warning or error — surfacing it as a
        /// print-affecting badge here would be a false positive, matching the false positive already
        /// hit and fixed relay-side (see nozzlecast-relay's hms-severity-badge design doc).
        public var issueSeverity: String?
        /// Count of currently active issues at `issueSeverity`'s tier or worse (severity <= 3).
        public var issueCount: Int?

        /// Extra detail about what the printer is actually doing right now, beyond `stateLabel`
        /// — Bambuddy's `stg_cur_name` (e.g. "Purifying the chamber air", "Heating chamber"),
        /// filtered down to cases that say something `stateLabel` doesn't already. In particular
        /// this is what's actually happening during the window after a print reaches 100% but
        /// before the printer moves off its running state to run post-print chamber
        /// purification — otherwise invisible from progress/stateLabel alone. Nil most of the
        /// time. Short by construction (Bambuddy's stage names top out well under 40 characters),
        /// so it costs little of the ~4KB content-state budget.
        public var stageDetail: String?

        /// The sliced-plate cover render, fetched once by the app when the print starts (it
        /// doesn't change during the print). Shown until a live snapshot arrives, and as the
        /// fallback whenever one hasn't.
        public var coverImage: Data?
        /// The printer's own camera frame, from Bambuddy's ntfy push attachment — refreshed by
        /// the notification extension on each progress event, independent of app refreshes.
        public var liveSnapshot: Data?

        /// Kept tiny deliberately: ActivityKit caps the whole content state at roughly 4KB
        /// serialized, a Data field costs ~33% more once base64-encoded into that JSON, and this
        /// state carries up to two images plus the fields above.
        public var preferredThumbnail: Data? { liveSnapshot ?? coverImage }

        public init(
            progress: Double,
            stateLabel: String,
            jobName: String? = nil,
            startedAt: Date,
            estimatedEndAt: Date? = nil,
            currentLayer: Int? = nil,
            totalLayers: Int? = nil,
            nozzleTempC: Int? = nil,
            bedTempC: Int? = nil,
            coverImage: Data? = nil,
            liveSnapshot: Data? = nil,
            issueSeverity: String? = nil,
            issueCount: Int? = nil,
            stageDetail: String? = nil
        ) {
            self.progress = progress
            self.stateLabel = stateLabel
            self.jobName = jobName
            self.startedAt = startedAt
            self.estimatedEndAt = estimatedEndAt
            self.currentLayer = currentLayer
            self.totalLayers = totalLayers
            self.nozzleTempC = nozzleTempC
            self.bedTempC = bedTempC
            self.coverImage = coverImage
            self.liveSnapshot = liveSnapshot
            self.issueSeverity = issueSeverity
            self.issueCount = issueCount
            self.stageDetail = stageDetail
        }
    }

    public var printerID: String
    public var printerName: String

    public init(printerID: String, printerName: String) {
        self.printerID = printerID
        self.printerName = printerName
    }
}

extension PrintActivityAttributes {
    /// The canonical matching key for a printer, derived from its display name rather than
    /// Bambuddy's numeric id. The app knows that numeric id; the notification extension only
    /// ever sees a printer name in push text (ntfy messages carry no printer id) — so an
    /// activity either side creates or updates has to be keyed on something both can compute
    /// the same way, which the numeric id isn't. Strips everything but letters/digits so
    /// "Vic H2C" and "vic-h2c" (Bambuddy uses both forms depending on the event) match.
    public static func normalizedID(_ printerName: String) -> String {
        printerName.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
