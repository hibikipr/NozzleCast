import ActivityKit
import Foundation

/// Mirrored in `NozzleCastWidgets/PrintActivityAttributes.swift` and
/// `NozzleCastNSE/PrintActivityAttributes.swift` — duplicated rather than shared for the same
/// reason as `PushSharedStore`: this project uses per-target file-system-synced groups, and
/// ActivityKit only requires structurally matching Codable types across the app/extension
/// process boundary, not a literal shared source reference. Keep all copies identical.
struct PrintActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var progress: Double
        var stateLabel: String
        var jobName: String?
        /// A date range consistent with the printer's current progress, used to drive a
        /// `ProgressView(timerInterval:)` that animates smoothly on-device between refreshes
        /// without needing a push for every tick.
        var startedAt: Date
        var estimatedEndAt: Date?

        var currentLayer: Int?
        var totalLayers: Int?
        var nozzleTempC: Int?
        var bedTempC: Int?

        /// The sliced-plate cover render, fetched once by the app when the print starts (it
        /// doesn't change during the print). Shown until a live snapshot arrives, and as the
        /// fallback whenever one hasn't.
        var coverImage: Data?
        /// The printer's own camera frame, from Bambuddy's ntfy push attachment — refreshed by
        /// the notification extension on each progress event, independent of app refreshes.
        var liveSnapshot: Data?

        /// Kept tiny deliberately: ActivityKit caps the whole content state at roughly 4KB
        /// serialized, a Data field costs ~33% more once base64-encoded into that JSON, and this
        /// state carries up to two images plus the fields above.
        var preferredThumbnail: Data? { liveSnapshot ?? coverImage }
    }

    var printerID: String
    var printerName: String
}

extension PrintActivityAttributes {
    /// The canonical matching key for a printer, derived from its display name rather than
    /// Bambuddy's numeric id. The app knows that numeric id; the notification extension only
    /// ever sees a printer name in push text (ntfy messages carry no printer id) — so an
    /// activity either side creates or updates has to be keyed on something both can compute
    /// the same way, which the numeric id isn't. Strips everything but letters/digits so
    /// "Vic H2C" and "vic-h2c" (Bambuddy uses both forms depending on the event) match.
    static func normalizedID(_ printerName: String) -> String {
        printerName.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
