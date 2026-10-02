import Foundation

/// The user's answer to "How did it come out?" for a finished print — Bambuddy's post-print
/// outcome confirmation (its #1898). Separate from whether the printer *finished*: a print can
/// complete without errors and still be a reject (warped, stringy, a layer shift).
enum PrintVerdict: String, Equatable {
    case good, reject
}

/// A job waiting in (or currently running from) Bambuddy's print queue.
struct QueuedPrint: Identifiable, Equatable {
    enum Status: Equatable { case pending, printing }

    enum Thumbnail: Equatable {
        case archive(Int)
        case libraryFile(Int)
    }

    var id: String
    var bambuddyID: Int
    var name: String
    /// Local printer ID (`bb-<n>`) when the job is pinned to one printer; nil for a job queued for
    /// any printer of a model.
    var printerID: String?
    /// The pinned printer's name, or "Any <model>" for a model-targeted job.
    var destination: String
    var status: Status
    var position: Int
    /// Waits for someone to press Start instead of dispatching when the printer frees up.
    var isStaged: Bool
    var scheduledAt: Date?
    /// Bambuddy's explanation for a pending job that can't go yet (wrong filament loaded, printer
    /// busy, …).
    var waitingReason: String?
    var estimatedDuration: TimeInterval?
    var filamentGrams: Double?
    var filamentType: String?
    var filamentColorHex: String?
    var thumbnail: Thumbnail?
}

/// One run in Bambuddy's print history. Reprints of the same file are separate records sharing an
/// `archiveID`.
struct PrintRecord: Identifiable, Equatable {
    enum Outcome: Equatable {
        case completed, failed, cancelled, other(String)

        init(_ raw: String) {
            switch raw.lowercased() {
            case "completed", "finished", "success": self = .completed
            case "failed", "error": self = .failed
            case "cancelled", "canceled", "aborted", "stopped": self = .cancelled
            default: self = .other(raw)
            }
        }
    }

    var id: String
    var logID: Int
    var archiveID: Int?
    var name: String
    var printerID: String?
    var printerName: String?
    var outcome: Outcome
    var startedAt: Date?
    var finishedAt: Date?
    var duration: TimeInterval?
    var filamentGrams: Double?
    var filamentType: String?
    var filamentColorHex: String?
    var cost: Double?
    var failureReason: String?
    var verdict: PrintVerdict?
    /// Whether "How did it come out?" can be answered for this record. Bambuddy stores the verdict
    /// on the print's archive and copies it to that archive's *latest* run only, so an older run of
    /// a reprinted file can't carry its own; and a print that failed or was cancelled already
    /// says how it came out.
    var acceptsVerdict: Bool

    /// How long after finishing a print still asks "How did it come out?" up front. Older
    /// unanswered prints can still be rated (long-press in History), they just don't nag — a
    /// server with hundreds of prints from before the feature existed would otherwise ask about
    /// every one of them.
    static let verdictPromptWindow: TimeInterval = 7 * 24 * 60 * 60

    /// Finished recently, can take a verdict, and nobody has given one.
    var isAwaitingVerdict: Bool {
        guard acceptsVerdict, verdict == nil, let finishedAt else { return false }
        return Date().timeIntervalSince(finishedAt) < Self.verdictPromptWindow
    }
}
