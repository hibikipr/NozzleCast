import XCTest
@testable import NozzleCastShared

/// The sharp cover the app saves for the Live Activity is matched to the print by job name, so a
/// cover from the printer's previous print is never shown on the next one.
final class LiveActivityCoverStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        LiveActivityCoverStore.directoryOverride = directory
    }

    override func tearDownWithError() throws {
        LiveActivityCoverStore.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testSavedCoverLoadsForTheSameJob() {
        LiveActivityCoverStore.save(Data([1, 2, 3]), printerID: "vich2c", jobName: "Flat base.3mf")
        XCTAssertEqual(LiveActivityCoverStore.load(printerID: "vich2c", jobName: "Flat base.3mf"), Data([1, 2, 3]))
        XCTAssertTrue(LiveActivityCoverStore.has(printerID: "vich2c", jobName: "Flat base.3mf"))
    }

    func testCoverFromAnotherJobIsNotShown() {
        LiveActivityCoverStore.save(Data([1]), printerID: "vich2c", jobName: "Old job.3mf")
        XCTAssertNil(LiveActivityCoverStore.load(printerID: "vich2c", jobName: "New job.3mf"))
        XCTAssertFalse(LiveActivityCoverStore.has(printerID: "vich2c", jobName: "New job.3mf"))
    }

    func testCoverIsPerPrinter() {
        LiveActivityCoverStore.save(Data([1]), printerID: "vich2c", jobName: "Part.3mf")
        XCTAssertNil(LiveActivityCoverStore.load(printerID: "samp1s", jobName: "Part.3mf"))
    }

    /// The app reads the job's file name while the relay's content-state carries Bambuddy's job
    /// name; they differ in the extension and case, not in the name itself.
    func testJobNamesMatchAcrossExtensionAndCase() {
        LiveActivityCoverStore.save(Data([1]), printerID: "vich2c", jobName: "Flat base to prevent rolling.gcode.3mf")
        XCTAssertNotNil(LiveActivityCoverStore.load(printerID: "vich2c", jobName: "flat base to prevent rolling"))
    }

    func testANewCoverReplacesTheOld() {
        LiveActivityCoverStore.save(Data([1]), printerID: "vich2c", jobName: "A.3mf")
        LiveActivityCoverStore.save(Data([2]), printerID: "vich2c", jobName: "B.3mf")
        XCTAssertEqual(LiveActivityCoverStore.load(printerID: "vich2c", jobName: "B.3mf"), Data([2]))
        XCTAssertNil(LiveActivityCoverStore.load(printerID: "vich2c", jobName: "A.3mf"))
    }

    func testNothingSavedLoadsNothing() {
        XCTAssertNil(LiveActivityCoverStore.load(printerID: "vich2c", jobName: "A.3mf"))
    }
}
