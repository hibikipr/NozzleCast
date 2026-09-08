import XCTest
@testable import NozzleCastShared

/// Bambuddy reports `remaining_time` as 0-3 seconds at the very start of a print, before it has
/// computed a real estimate — and for at least one test G-code file, seemingly never computes one.
/// Taken at face value that renders an "Est. finish" clock time a couple of minutes out on a print
/// with hours left. The relay has rejected these since it first saw one live; the app did not, so
/// foregrounding it during that window overwrote the relay's correctly-omitted estimate with a
/// wrong one.
final class RemainingTimeTrustTests: XCTestCase {

    func testAPlausibleEstimateIsTrusted() {
        XCTAssertTrue(RemainingTimeTrust.isTrustworthy(remainingMinutes: 42, progress: 0.3))
    }

    func testANearZeroEstimateEarlyInAPrintIsRejected() {
        XCTAssertFalse(RemainingTimeTrust.isTrustworthy(remainingMinutes: 0, progress: 0.02))
    }

    func testASubMinuteEstimateMidPrintIsRejected() {
        XCTAssertFalse(RemainingTimeTrust.isTrustworthy(remainingMinutes: 0.4, progress: 0.5))
    }

    /// The one case where a near-zero remaining time is the truth rather than a placeholder: the
    /// print really is about to finish.
    func testANearZeroEstimateIsTrustedOnceThePrintIsNearlyComplete() {
        XCTAssertTrue(RemainingTimeTrust.isTrustworthy(remainingMinutes: 0, progress: 0.97))
    }

    func testTheNearCompletionBoundaryItselfIsTrusted() {
        XCTAssertTrue(RemainingTimeTrust.isTrustworthy(remainingMinutes: 0, progress: 0.95))
    }

    func testJustBelowTheNearCompletionBoundaryIsNotTrusted() {
        XCTAssertFalse(RemainingTimeTrust.isTrustworthy(remainingMinutes: 0, progress: 0.94))
    }

    /// Matches the relay's own threshold exactly (0.5 min): the two must agree, or the estimate
    /// will visibly change the moment a relay-driven activity is touched by the app.
    func testTheTrustedMinimumBoundaryIsInclusive() {
        XCTAssertTrue(RemainingTimeTrust.isTrustworthy(remainingMinutes: 0.5, progress: 0.1))
    }

    /// No progress reading at all: an implausible time cannot be excused by a completion it
    /// cannot check, so it stays rejected.
    func testAnImplausibleEstimateWithNoProgressReadingIsRejected() {
        XCTAssertFalse(RemainingTimeTrust.isTrustworthy(remainingMinutes: 0, progress: nil))
    }

    func testAPlausibleEstimateWithNoProgressReadingIsStillTrusted() {
        XCTAssertTrue(RemainingTimeTrust.isTrustworthy(remainingMinutes: 90, progress: nil))
    }
}
