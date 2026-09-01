import ActivityKit
import Foundation

/// Mirrored in `NozzleCastWidgets/PrintActivityAttributes.swift` — duplicated rather than shared
/// for the same reason as `PushSharedStore`: this project uses per-target file-system-synced
/// groups, and ActivityKit only requires structurally matching Codable types across the app/
/// extension process boundary, not a literal shared source reference. Keep both copies identical.
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
        /// A small, heavily-compressed JPEG of the job's cover/plate image — kept tiny since
        /// ActivityKit caps the whole content state at roughly 4KB serialized.
        var coverThumbnail: Data?
    }

    var printerID: String
    var printerName: String
}
