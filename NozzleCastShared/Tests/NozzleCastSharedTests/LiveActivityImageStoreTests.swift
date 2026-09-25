import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
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

    func testLatestFrameRoundTrips() {
        let data = Data("frame".utf8)
        LiveActivityImageStore.save(data, printerID: "vich2c", in: directory)
        XCTAssertEqual(LiveActivityImageStore.latestFrame(printerID: "vich2c", in: directory, now: Date()), data)
        XCTAssertNil(LiveActivityImageStore.latestFrame(printerID: "other", in: directory, now: Date()))
    }

    /// A newer write replaces the older frame rather than piling up files.
    func testOverwritesPerPrinter() throws {
        LiveActivityImageStore.save(Data("a".utf8), printerID: "p1s", in: directory)
        LiveActivityImageStore.save(Data("b".utf8), printerID: "p1s", in: directory)
        XCTAssertEqual(LiveActivityImageStore.latestFrame(printerID: "p1s", in: directory, now: Date()), Data("b".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }

    func testStaleFrameIsIgnored() {
        LiveActivityImageStore.save(Data("a".utf8), printerID: "p1s", in: directory)
        let later = Date().addingTimeInterval(LiveActivityImageStore.maxFrameAge + 60)
        XCTAssertNil(LiveActivityImageStore.latestFrame(printerID: "p1s", in: directory, now: later))
    }

    func testDownscalesToMaxPixelSize() throws {
        let jpeg = try XCTUnwrap(LiveActivityImageStore.downscaledJPEG(Self.makeJPEG(width: 1280, height: 720)))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(max(image.width, image.height), LiveActivityImageStore.maxPixelSize)
    }

    func testRejectsUndecodableData() {
        XCTAssertNil(LiveActivityImageStore.downscaledJPEG(Data("not an image".utf8)))
    }

    func testPrinterIDsPrefersLongestMatch() {
        let haystack = "printstartedp1s2lessfilament"
        XCTAssertEqual(LiveActivityImageStore.printerIDs(in: haystack, candidates: ["p1s", "p1s2", "x1c"]), ["p1s2"])
        XCTAssertEqual(LiveActivityImageStore.printerIDs(in: "vich2cstarted", candidates: ["vich2c", ""]), ["vich2c"])
        XCTAssertEqual(LiveActivityImageStore.printerIDs(in: "nothing", candidates: ["p1s"]), [])
    }

    private static func makeJPEG(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
