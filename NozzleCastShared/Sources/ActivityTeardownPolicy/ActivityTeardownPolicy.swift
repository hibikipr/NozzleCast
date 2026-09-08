import Foundation

/// Whether the app should end a Live Activity itself, and the anchor to carry into the next
/// observation.
public struct TeardownDecision: Equatable {
    /// When this printer was FIRST seen in a confirmed-terminal state while its activity was
    /// still live. Nil means the clock isn't running. Callers persist this per printer between
    /// observations and hand it back on the next one.
    public let anchor: Date?
    public let shouldEnd: Bool

    public init(anchor: Date?, shouldEnd: Bool) {
        self.anchor = anchor
        self.shouldEnd = shouldEnd
    }
}

/// Decides when the app may tear down a Live Activity the relay owns.
///
/// The relay is the primary owner of a print's activity: it starts it via push-to-start and ends
/// it with an explicit `end` push when Bambuddy reports the print finished, stopped, or failed.
/// This policy is only the backstop for a relay that never sends that push -- down, restarting,
/// or misconfigured -- so the rule is deliberately conservative in one specific direction.
///
/// It fires on a POSITIVE signal ("Bambuddy says this job is over"), never on the absence of a
/// "still printing" one. That distinction is the entire fix: the previous implementation ended
/// any activity whose printer wasn't reporting `.printing` at that instant, which meant a
/// mid-print HMS warning, a pause, a momentary disconnect, one failed `/status` fetch, or simply
/// Bambuddy's 5-10s REST lag right after push-to-start all read as "this print is over."
public enum ActivityTeardown {
    /// Default grace period. Comfortably clears both Bambuddy's REST lag at print start and the
    /// relay's own detect-and-push latency (a 15s poll plus one APNs round trip), while still
    /// clearing a genuinely orphaned activity in minutes rather than at ActivityKit's own
    /// multi-hour ceiling.
    public static let defaultWindow: TimeInterval = 180

    /// - Parameters:
    ///   - isActiveJob: `true` if Bambuddy reports this printer is in a job (running or paused,
    ///     regardless of any HMS badge), `false` if it is reachable and reports no job, and `nil`
    ///     if we have no usable reading at all (offline, or the status fetch failed).
    ///   - anchor: the previous decision's `anchor` for this printer.
    public static func evaluate(
        isActiveJob: Bool?,
        anchor: Date?,
        now: Date,
        window: TimeInterval = defaultWindow
    ) -> TeardownDecision {
        guard let isActiveJob else {
            // No reading. Neither starts nor advances nor clears the clock -- an unreachable
            // printer tells us nothing about whether its print ended.
            return TeardownDecision(anchor: anchor, shouldEnd: false)
        }

        guard !isActiveJob else {
            return TeardownDecision(anchor: nil, shouldEnd: false)
        }

        // Confirmed terminal. Keep the original anchor if the clock is already running, so the
        // window measures from the FIRST such observation rather than restarting on each one.
        let started = anchor ?? now
        return TeardownDecision(anchor: started, shouldEnd: now.timeIntervalSince(started) >= window)
    }
}
