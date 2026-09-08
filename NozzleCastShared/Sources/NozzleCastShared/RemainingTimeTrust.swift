import Foundation

/// Whether Bambuddy's reported `remaining_time` is worth showing as an estimated finish time.
///
/// Bambuddy reports 0-3 *seconds* remaining at the very start of a print, before it has computed a
/// real estimate — and for at least one test G-code file, seemingly never computes one at all.
/// Rendered literally that becomes an "Est. finish" clock time a couple of minutes away on a print
/// with hours left, which is worse than showing nothing: the widget's layout handles a missing
/// estimate cleanly and shows a wrong one just as confidently as a right one.
///
/// Deliberately mirrors `isRemainingTimeTrustworthy` in the relay's `bambuddyEnrichment.js`,
/// thresholds included. The two write the same field of the same Live Activity, so if they
/// disagree the estimate visibly changes the moment one of them touches an activity the other
/// last wrote.
public enum RemainingTimeTrust {
    /// Below this, an estimate is treated as Bambuddy's not-yet-computed placeholder rather than a
    /// real number.
    public static let minimumTrustedMinutes: Double = 0.5
    /// ...unless the print really is nearly done, which is the one case where a near-zero
    /// remaining time is the truth.
    public static let nearCompletionProgress: Double = 0.95

    public static func isTrustworthy(remainingMinutes: Double, progress: Double?) -> Bool {
        if remainingMinutes >= minimumTrustedMinutes { return true }
        guard let progress else { return false }
        return progress >= nearCompletionProgress
    }
}
