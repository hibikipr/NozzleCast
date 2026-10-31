import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import NozzleCastShared

/// The Live Activity's cover tile shows Bambu's plate render: the model on a mostly transparent
/// canvas. These pin down the three things that made it blurry and invisible — wasted margin, a
/// backdrop that hid the filament colour, and a byte budget that has to hold exactly.
final class CoverImageProcessingTests: XCTestCase {

    // MARK: - Fixtures

    /// A `canvas`-square transparent image with an opaque `color` block (the model) centred in it,
    /// optionally with its top-right quarter cut out so the trimmed image keeps a backdrop corner.
    private func modelImage(canvas: Int = 200, modelWidth: Int = 60, modelHeight: Int = 100,
                            color: (CGFloat, CGFloat, CGFloat), notched: Bool = false) -> CGImage {
        let context = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
        context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
        let model = CGRect(x: (canvas - modelWidth) / 2, y: (canvas - modelHeight) / 2, width: modelWidth, height: modelHeight)
        context.fill(model)
        if notched {
            // CoreGraphics' origin is bottom-left, so the top-right quarter is at maxX/maxY.
            context.clear(CGRect(x: model.midX, y: model.midY, width: model.width / 2, height: model.height / 2))
        }
        return context.makeImage()!
    }

    private func pngData(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private func decode(_ data: Data) -> CGImage {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCreateImageAtIndex(source, 0, nil)!
    }

    private func assertNear(_ actual: CoverImageProcessing.RGB, _ expected: CoverImageProcessing.RGB,
                            tolerance: Int = 10, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let pairs = [(actual.red, expected.red), (actual.green, expected.green), (actual.blue, expected.blue)]
        for (a, e) in pairs where abs(Int(a) - Int(e)) > tolerance {
            XCTFail("\(label): expected ~\(expected), got \(actual)", file: file, line: line)
            return
        }
    }

    // MARK: - Trim and size

    /// A real 512x512 render's model spans only 184x215, so without the trim most of the pixels
    /// described empty canvas.
    func testTrimsTheTransparentMarginSoTheModelFillsTheImage() throws {
        let image = modelImage(modelWidth: 50, modelHeight: 100, color: (0.8, 0.2, 0.2))
        let processed = try XCTUnwrap(CoverImageProcessing.prepared(image, maxDimension: 96))

        XCTAssertEqual(processed.height, 96)
        XCTAssertEqual(processed.width, 48)
    }

    func testNeverEnlargesASmallCover() throws {
        let image = modelImage(canvas: 40, modelWidth: 10, modelHeight: 20, color: (0.8, 0.2, 0.2))
        let processed = try XCTUnwrap(CoverImageProcessing.prepared(image, maxDimension: 96))

        XCTAssertEqual(processed.width, 10)
        XCTAssertEqual(processed.height, 20)
    }

    // MARK: - Backdrop

    /// A dark filament vanished when the transparency became black, and a fixed mid-grey hid grey
    /// models instead, so the backdrop follows the model.
    func testDarkModelGoesOnTheLightBackdrop() throws {
        let image = modelImage(color: (0.16, 0.12, 0.35), notched: true)
        let processed = try XCTUnwrap(CoverImageProcessing.prepared(image, maxDimension: 96))

        assertNear(try XCTUnwrap(CoverImageProcessing.topRightColor(of: processed)), CoverImageProcessing.backdropLight, "backdrop behind a dark model")
    }

    func testLightModelGoesOnTheDarkBackdrop() throws {
        let image = modelImage(color: (0.67, 0.67, 0.67), notched: true)
        let processed = try XCTUnwrap(CoverImageProcessing.prepared(image, maxDimension: 96))

        assertNear(try XCTUnwrap(CoverImageProcessing.topRightColor(of: processed)), CoverImageProcessing.backdropDark, "backdrop behind a light model")
    }

    /// The relay's backdrops (imageDownscale.js BACKDROP_DARK/LIGHT) must be the same colours, or
    /// a cover would change shade depending on which side produced it.
    /// The widget fills the rest of its tile with the cover's backdrop. A boxy model can fill the
    /// trimmed image right into a corner, so it snaps the corners to the nearer known backdrop
    /// rather than copying a pixel that might be filament.
    func testBackdropOfACoverSnapsToTheKnownBackdrops() throws {
        let dark = try XCTUnwrap(CoverImageProcessing.prepared(modelImage(color: (0.16, 0.12, 0.35), notched: true), maxDimension: 96))
        let light = try XCTUnwrap(CoverImageProcessing.prepared(modelImage(color: (0.67, 0.67, 0.67), notched: true), maxDimension: 96))
        XCTAssertEqual(CoverImageProcessing.backdrop(of: dark), CoverImageProcessing.backdropLight)
        XCTAssertEqual(CoverImageProcessing.backdrop(of: light), CoverImageProcessing.backdropDark)
    }

    func testBackdropsMatchTheRelay() {
        XCTAssertEqual(CoverImageProcessing.backdropDark, CoverImageProcessing.RGB(red: 0x1F, green: 0x23, blue: 0x29))
        XCTAssertEqual(CoverImageProcessing.backdropLight, CoverImageProcessing.RGB(red: 0xC4, green: 0xC9, blue: 0xD1))
    }

    // MARK: - Encoding

    func testFallbackFitsTheByteBudget() throws {
        let data = pngData(modelImage(color: (0.8, 0.4, 0.1), notched: true))
        let fallback = try XCTUnwrap(CoverImageProcessing.contentStateCover(from: data))

        XCTAssertLessThanOrEqual(fallback.count, CoverImageProcessing.contentStateMaxBytes)
        let decoded = decode(fallback)
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), CoverImageProcessing.contentStateMaxDimension)
    }

    func testFallbackIsNilWhenNothingFits() {
        let data = pngData(modelImage(color: (0.8, 0.4, 0.1)))
        XCTAssertNil(CoverImageProcessing.contentStateCover(from: data, maxBytes: 1))
    }

    func testSharpCoverKeepsDetailUpToItsLimit() throws {
        let data = pngData(modelImage(canvas: 1024, modelWidth: 600, modelHeight: 900, color: (0.8, 0.4, 0.1)))
        let sharp = try XCTUnwrap(CoverImageProcessing.sharpCover(from: data))

        let decoded = decode(sharp)
        XCTAssertEqual(max(decoded.width, decoded.height), CoverImageProcessing.sharpMaxDimension)
    }

    func testUnreadableDataGivesNoCover() {
        XCTAssertNil(CoverImageProcessing.sharpCover(from: Data("not an image".utf8)))
        XCTAssertNil(CoverImageProcessing.contentStateCover(from: Data("not an image".utf8)))
    }

    func testFullyTransparentImageGivesNoCover() {
        let empty = modelImage(modelWidth: 0, modelHeight: 0, color: (0, 0, 0))
        XCTAssertNil(CoverImageProcessing.prepared(empty, maxDimension: 96))
    }
}
