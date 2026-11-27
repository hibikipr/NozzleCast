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

    /// A pending job that is not staged but waits only because a spool is too short (Bambuddy's
    /// "Loaded filament first" setting, #3587). It has no Start, but it can be released with
    /// "Print Anyway", which asks the same insufficient-filament question as a staged one (#3659).
    var waitsForShortFilament: Bool {
        status == .pending && !isStaged && Self.isShortFilamentWait(waitingReason)
    }

    /// Whether a `waiting_reason` says a spool is too short, as Bambuddy's queue page reads it
    /// (`isShortFilamentWaitingReason`): a "Waiting for filament: " part naming "(needs more
    /// filament)", "(20 g left, needs 300 g)" or "(needs 300 g)". A filament that isn't loaded
    /// at all reads "PLA #FFFFFF" and is not one.
    static func isShortFilamentWait(_ reason: String?) -> Bool {
        guard let reason, !reason.isEmpty else { return false }
        let short = #"\(needs more filament\)|\(\d+ g left, needs \d+ g\)|\(needs \d+ g\)"#
        return reason.components(separatedBy: " | ").contains { part in
            part.contains("Waiting for filament: ") && part.range(of: short, options: .regularExpression) != nil
        }
    }
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
    /// Whether "How did it come out?" can be answered for this record. Bambuddy 1.3.0+ keeps a
    /// verdict on each print of an archive; before that it stored one on the archive and copied it
    /// to the archive's *latest* run only, so an older run of a reprinted file couldn't carry its
    /// own. A print that failed or was cancelled already says how it came out.
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
