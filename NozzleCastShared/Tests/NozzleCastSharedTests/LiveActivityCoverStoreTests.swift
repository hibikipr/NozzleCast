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
        XCTAssertNil(LiveActivityCoverStore.loadCover(printerID: "vich2c", jobName: "A.3mf"))
    }

    func testBackdropIsLightRoundTripsViaLoadCover() {
        LiveActivityCoverStore.save(Data([10, 20]), printerID: "vich2c", jobName: "DarkModel.3mf", backdropIsLight: true)
        let lightCover = LiveActivityCoverStore.loadCover(printerID: "vich2c", jobName: "DarkModel")
        XCTAssertEqual(lightCover?.data, Data([10, 20]))
        XCTAssertEqual(lightCover?.backdropIsLight, true)

        LiveActivityCoverStore.save(Data([30, 40]), printerID: "vich2c", jobName: "LightModel.3mf", backdropIsLight: false)
        let darkCover = LiveActivityCoverStore.loadCover(printerID: "vich2c", jobName: "LightModel")
        XCTAssertEqual(darkCover?.data, Data([30, 40]))
        XCTAssertEqual(darkCover?.backdropIsLight, false)

        LiveActivityCoverStore.save(Data([50]), printerID: "vich2c", jobName: "NoHint.3mf")
        let noHintCover = LiveActivityCoverStore.loadCover(printerID: "vich2c", jobName: "NoHint")
        XCTAssertEqual(noHintCover?.data, Data([50]))
        XCTAssertNil(noHintCover?.backdropIsLight)
    }

    func testLegacyFilesWithoutImageFilenameOrBackdropHintStillLoad() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([7, 8, 9]).write(to: directory.appendingPathComponent("vich2c.jpg"))
        try Data("{\"job\":\"legacy part\"}".utf8).write(to: directory.appendingPathComponent("vich2c.json"))

        XCTAssertEqual(LiveActivityCoverStore.load(printerID: "vich2c", jobName: "Legacy Part.3mf"), Data([7, 8, 9]))
        let loaded = LiveActivityCoverStore.loadCover(printerID: "vich2c", jobName: "Legacy Part.3mf")
        XCTAssertEqual(loaded?.data, Data([7, 8, 9]))
        XCTAssertNil(loaded?.backdropIsLight)
    }

    func testReplacingCoverCleansUpLegacyAndPreviousJobImagesWithoutTouchingOtherPrinters() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyFile = directory.appendingPathComponent("vich2c.jpg")
        try Data([99]).write(to: legacyFile)

        LiveActivityCoverStore.save(Data([1]), printerID: "vich2c2", jobName: "Other.3mf")
        LiveActivityCoverStore.save(Data([2]), printerID: "vich2c", jobName: "JobA.3mf")
        LiveActivityCoverStore.save(Data([3]), printerID: "vich2c", jobName: "JobB.3mf")

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
        let vich2cJpgs = files.filter { $0 == "vich2c.jpg" || ($0.hasPrefix("vich2c-") && $0.hasSuffix(".jpg")) }
        let vich2c2Jpgs = files.filter { $0.hasPrefix("vich2c2-") && $0.hasSuffix(".jpg") }

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
        XCTAssertEqual(vich2cJpgs.count, 1)
        XCTAssertEqual(vich2c2Jpgs.count, 1)
        XCTAssertEqual(LiveActivityCoverStore.load(printerID: "vich2c", jobName: "JobB.3mf"), Data([3]))
        XCTAssertEqual(LiveActivityCoverStore.load(printerID: "vich2c2", jobName: "Other.3mf"), Data([1]))
    }

    func testFailedImageWritePreservesExistingMetadataAndCover() throws {
        let customDir = directory.appendingPathComponent("custom", isDirectory: true)
        LiveActivityCoverStore.save(Data([1, 2, 3]), printerID: "vich2c", jobName: "JobA.3mf", backdropIsLight: true, directory: customDir)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: customDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: customDir.path) }

        LiveActivityCoverStore.save(Data([4, 5, 6]), printerID: "vich2c", jobName: "JobB.3mf", backdropIsLight: false, directory: customDir)

        let loaded = LiveActivityCoverStore.loadCover(printerID: "vich2c", jobName: "JobA.3mf", directory: customDir)
        XCTAssertEqual(loaded?.data, Data([1, 2, 3]))
        XCTAssertEqual(loaded?.backdropIsLight, true)
        XCTAssertNil(LiveActivityCoverStore.loadCover(printerID: "vich2c", jobName: "JobB.3mf", directory: customDir))
    }
}
