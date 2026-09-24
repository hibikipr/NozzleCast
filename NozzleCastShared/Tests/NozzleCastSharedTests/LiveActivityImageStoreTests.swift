import XCTest
@testable import NozzleCastShared

final class LiveActivityImageStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveActivityImageStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSaveThenLoadRoundTrips() throws {
        let data = Data("frame".utf8)
        let name = try XCTUnwrap(LiveActivityImageStore.save(data, printerID: "vich2c", in: directory, now: Date()))
        XCTAssertEqual(LiveActivityImageStore.load(fileName: name, in: directory), data)
    }

    /// A reused name would leave the content state unchanged, so the widget would never re-render.
    func testEveryWriteGetsANewName() throws {
        let now = Date()
        let a = try XCTUnwrap(LiveActivityImageStore.save(Data("a".utf8), printerID: "p1s", in: directory, now: now))
        let b = try XCTUnwrap(LiveActivityImageStore.save(Data("b".utf8), printerID: "p1s", in: directory, now: now))
        XCTAssertNotEqual(a, b)
    }

    func testPrunesToNewestFilesPerPrinterOnly() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var names: [String] = []
        for i in 0..<5 {
            let name = LiveActivityImageStore.save(Data([UInt8(i)]), printerID: "p1s", in: directory, now: start.addingTimeInterval(Double(i)))
            names.append(try XCTUnwrap(name))
        }
        let other = try XCTUnwrap(LiveActivityImageStore.save(Data("x".utf8), printerID: "x1c", in: directory, now: start))

        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        XCTAssertEqual(remaining, Set(names.suffix(LiveActivityImageStore.retainedPerPrinter) + [other]))
    }

    func testRejectsPathTraversal() {
        XCTAssertNil(LiveActivityImageStore.load(fileName: "../secret", in: directory))
        XCTAssertNil(LiveActivityImageStore.load(fileName: "a/b.jpg", in: directory))
        XCTAssertNil(LiveActivityImageStore.load(fileName: "", in: directory))
    }
}
