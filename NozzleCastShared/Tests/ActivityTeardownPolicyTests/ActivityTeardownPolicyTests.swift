import XCTest
@testable import ActivityTeardownPolicy

/// The grace period the relay gets to send its own `end` push before the app tears an activity
/// down itself. Named rather than inlined so the tests read as intent, not arithmetic.
private let window: TimeInterval = 180
private let t0 = Date(timeIntervalSinceReferenceDate: 0)
private func t(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

/// `isActiveJob` is deliberately three-valued, and that is the whole point of this policy:
///   true  -- Bambuddy says this printer is in a job (running OR paused, error badge or not)
///   false -- Bambuddy is reachable and says the job is over
///   nil   -- we have no data (printer offline, /status fetch failed)
/// The bug this replaces treated `nil` and `false` alike, so a single unreachable poll ended a
/// live print's activity. Absence of evidence is not evidence of a finished print.
final class ActivityTeardownPolicyTests: XCTestCase {

    // MARK: - Active job

    func testActiveJobNeverEnds() {
        let decision = ActivityTeardown.evaluate(isActiveJob: true, anchor: nil, now: t0, window: window)
        XCTAssertFalse(decision.shouldEnd)
    }

    func testActiveJobClearsAnExistingAnchor() {
        let decision = ActivityTeardown.evaluate(isActiveJob: true, anchor: t0, now: t(60), window: window)
        XCTAssertNil(decision.anchor)
    }

    /// The start-of-print case that broke in production: Bambuddy's REST API lags 5-10s behind
    /// the print-start event, so the first observation after push-to-start still reads the
    /// PREVIOUS job's terminal state. It anchors, then clears once Bambuddy catches up -- and
    /// because the window never elapsed, the activity is never torn down.
    func testTerminalThenActiveWithinWindowNeverEnds() {
        let anchored = ActivityTeardown.evaluate(isActiveJob: false, anchor: nil, now: t(1), window: window)
        XCTAssertFalse(anchored.shouldEnd)

        let caughtUp = ActivityTeardown.evaluate(isActiveJob: true, anchor: anchored.anchor, now: t(10), window: window)
        XCTAssertNil(caughtUp.anchor)
        XCTAssertFalse(caughtUp.shouldEnd)
    }

    // MARK: - Terminal job

    func testFirstTerminalObservationAnchorsWithoutEnding() {
        let decision = ActivityTeardown.evaluate(isActiveJob: false, anchor: nil, now: t(50), window: window)
        XCTAssertEqual(decision.anchor, t(50))
        XCTAssertFalse(decision.shouldEnd)
    }

    func testTerminalObservationKeepsTheOriginalAnchor() {
        let decision = ActivityTeardown.evaluate(isActiveJob: false, anchor: t0, now: t(60), window: window)
        XCTAssertEqual(decision.anchor, t0)
    }

    func testTerminalInsideTheWindowDoesNotEnd() {
        let decision = ActivityTeardown.evaluate(isActiveJob: false, anchor: t0, now: t(179), window: window)
        XCTAssertFalse(decision.shouldEnd)
    }

    func testTerminalAtTheWindowBoundaryEnds() {
        let decision = ActivityTeardown.evaluate(isActiveJob: false, anchor: t0, now: t(180), window: window)
        XCTAssertTrue(decision.shouldEnd)
    }

    func testTerminalPastTheWindowEnds() {
        let decision = ActivityTeardown.evaluate(isActiveJob: false, anchor: t0, now: t(600), window: window)
        XCTAssertTrue(decision.shouldEnd)
    }

    // MARK: - No data

    func testNoDataNeverEndsEvenLongPastTheWindow() {
        let decision = ActivityTeardown.evaluate(isActiveJob: nil, anchor: t0, now: t(6000), window: window)
        XCTAssertFalse(decision.shouldEnd)
    }

    func testNoDataLeavesAnExistingAnchorUntouched() {
        let decision = ActivityTeardown.evaluate(isActiveJob: nil, anchor: t0, now: t(60), window: window)
        XCTAssertEqual(decision.anchor, t0)
    }

    func testNoDataDoesNotStartTheClock() {
        let decision = ActivityTeardown.evaluate(isActiveJob: nil, anchor: nil, now: t(60), window: window)
        XCTAssertNil(decision.anchor)
    }

    /// An unreachable printer mid-window must not let the window keep running against it: once
    /// Bambuddy comes back and confirms the job really is over, the original anchor still governs.
    func testNoDataBetweenTerminalObservationsPreservesTheClock() {
        let anchored = ActivityTeardown.evaluate(isActiveJob: false, anchor: nil, now: t0, window: window)
        let offline = ActivityTeardown.evaluate(isActiveJob: nil, anchor: anchored.anchor, now: t(90), window: window)
        let back = ActivityTeardown.evaluate(isActiveJob: false, anchor: offline.anchor, now: t(200), window: window)
        XCTAssertTrue(back.shouldEnd)
    }
}
