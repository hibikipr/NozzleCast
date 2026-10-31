import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns Bambu's plate cover render — the model on a mostly transparent canvas — into the images
/// the Live Activity shows: a sharp copy the app saves for it (`sharpCover`), and a small fallback
/// that rides in the content-state itself (`contentStateCover`).
///
/// Both are trimmed to the model (a real 512x512 render's model spanned only 184x215) and
/// flattened onto a backdrop that follows the model's brightness — a single fixed colour always
/// hid some filament: black swallowed dark models, mid-grey swallowed grey ones. nozzlecast-relay's
/// `imageDownscale.js` does the same for the fallback it sends, with the same two backdrops, so a
/// cover looks the same whichever side produced it. CoreGraphics only (no UIKit) so it's tested on
/// macOS with `swift test`.
public enum CoverImageProcessing {
    public struct RGB: Equatable, Sendable, CustomStringConvertible {
        public var red: UInt8
        public var green: UInt8
        public var blue: UInt8

        public init(red: UInt8, green: UInt8, blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        public var description: String { "(\(red), \(green), \(blue))" }

        var cgColor: CGColor {
            CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        }
    }

    /// Behind a light model. Must match the relay's BACKDROP_DARK.
    public static let backdropDark = RGB(red: 0x1F, green: 0x23, blue: 0x29)
    /// Behind a dark model. Must match the relay's BACKDROP_LIGHT.
    public static let backdropLight = RGB(red: 0xC4, green: 0xC9, blue: 0xD1)

    /// The content-state fallback's caps: ActivityKit ends the whole Live Activity if its
    /// serialized content-state goes over ~4KB, and a Data field grows ~33% once base64-encoded.
    /// Match the relay's COVER_IMAGE_MAX_DIMENSION / COVER_IMAGE_MAX_BYTES.
    public static let contentStateMaxDimension = 96
    public static let contentStateMaxBytes = 2200
    /// The saved sharp copy: the Lock Screen tile is 96x128pt, so 384px covers it at 3x.
    public static let sharpMaxDimension = 384

    /// Average relative luminance (0-1) above which a model counts as light.
    private static let lightModelThreshold = 0.5
    /// Alpha (0-255) from which a pixel counts as model, for the trim and the luminance average.
    private static let trimAlphaThreshold: UInt8 = 8
    private static let modelAlphaThreshold: UInt8 = 128

    // MARK: - Public entry points

    /// The sharp copy the app saves for the Live Activity (JPEG; size isn't budgeted).
    public static func sharpCover(from data: Data) -> Data? {
        guard let image = decode(data), let prepared = prepared(image, maxDimension: sharpMaxDimension) else { return nil }
        return jpeg(prepared, quality: 0.9)
    }

    /// The fallback that rides in the content-state, as JPEG within `maxBytes`: quality starts at
    /// 0.95 and steps down by 0.05, returning the first — i.e. best — encoding that fits, or nil
    /// if even 0.1 doesn't (fails closed: a blown budget ends the whole activity). iOS can't encode
    /// WebP, which the relay uses for the same budget, so this one is JPEG.
    public static func contentStateCover(from data: Data, maxDimension: Int = contentStateMaxDimension,
                                         maxBytes: Int = contentStateMaxBytes) -> Data? {
        guard let image = decode(data), let prepared = prepared(image, maxDimension: maxDimension) else { return nil }
        var quality = 0.95
        while quality >= 0.1 - 1e-9 {
            if let encoded = jpeg(prepared, quality: quality), encoded.count <= maxBytes { return encoded }
            quality -= 0.05
        }
        return nil
    }

    /// The backdrop a prepared cover was flattened onto, for filling the rest of the tile it's
    /// shown in. A boxy model can reach right into a corner, so this doesn't copy a corner pixel:
    /// it counts the corners that are (within JPEG/WebP noise) one of the two backdrops — model
    /// pixels almost never are — and only when none is falls back to whichever backdrop the
    /// corners are nearer.
    /// The backdrop for a raw cover render (transparent background, untrimmed): what the app puts
    /// behind a cover it shows, so it matches the Live Activity's. Dark for a light model, light
    /// for a dark one; dark when the render has no visible pixels.
    public static func backdrop(forRender image: CGImage) -> RGB {
        guard let pixels = rgbaPixels(of: image), let box = pixels.opaqueBounds(threshold: trimAlphaThreshold) else { return backdropDark }
        return backdrop(forModelIn: pixels, box: box)
    }

    private static func backdrop(forModelIn pixels: Pixels, box: CGRect) -> RGB {
        pixels.averageLuminance(in: box, alphaThreshold: modelAlphaThreshold) > lightModelThreshold ? backdropDark : backdropLight
    }

    public static func backdrop(of image: CGImage) -> RGB {
        guard let pixels = rgbaPixels(of: image) else { return backdropDark }
        let width = image.width, height = image.height
        let corners = [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)].map { pixels.pixel(x: $0.0, y: $0.1) }
        let matchTolerance = 3 * 14 * 14
        let darkMatches = corners.filter { distance($0, backdropDark) <= matchTolerance }.count
        let lightMatches = corners.filter { distance($0, backdropLight) <= matchTolerance }.count
        if darkMatches != lightMatches { return darkMatches > lightMatches ? backdropDark : backdropLight }
        let toDark = corners.map { distance($0, backdropDark) }.reduce(0, +)
        let toLight = corners.map { distance($0, backdropLight) }.reduce(0, +)
        return toDark <= toLight ? backdropDark : backdropLight
    }

    // MARK: - Steps

    /// Trimmed to the model, scaled to fit `maxDimension` (never enlarged) and flattened onto the
    /// backdrop for its brightness. Nil when the image has no visible pixels at all.
    static func prepared(_ image: CGImage, maxDimension: Int) -> CGImage? {
        guard let pixels = rgbaPixels(of: image), let box = pixels.opaqueBounds(threshold: trimAlphaThreshold),
              let cropped = image.cropping(to: box)
        else { return nil }

        let backdrop = backdrop(forModelIn: pixels, box: box)

        let scale = min(Double(maxDimension) / Double(max(box.width, box.height)), 1)
        let width = max(Int((Double(box.width) * scale).rounded()), 1)
        let height = max(Int((Double(box.height) * scale).rounded()), 1)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.setFillColor(backdrop.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// The image's top-right pixel, for tests to see the backdrop a notched model leaves there.
    static func topRightColor(of image: CGImage) -> RGB? {
        rgbaPixels(of: image)?.pixel(x: image.width - 1, y: 0)
    }

    // MARK: - Helpers

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Bounded decode: a cover is at most a few hundred pixels once trimmed, so there's no
        // point holding a full-resolution render in an extension's tight memory.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func distance(_ a: RGB, _ b: RGB) -> Int {
        let dr = Int(a.red) - Int(b.red), dg = Int(a.green) - Int(b.green), db = Int(a.blue) - Int(b.blue)
        return dr * dr + dg * dg + db * db
    }

    /// The image redrawn as RGBA (premultiplied; `Pixels.pixel` undoes that), row 0 at the top.
    private static func rgbaPixels(of image: CGImage) -> Pixels? {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        return Pixels(bytes: bytes, width: width, height: height)
    }

    private struct Pixels {
        let bytes: [UInt8]
        let width: Int
        let height: Int

        func alpha(x: Int, y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }

        func pixel(x: Int, y: Int) -> RGB {
            let offset = (y * width + x) * 4
            let alpha = Double(bytes[offset + 3])
            guard alpha > 0 else { return RGB(red: 0, green: 0, blue: 0) }
            func unpremultiplied(_ value: UInt8) -> UInt8 { UInt8(min(Double(value) * 255 / alpha, 255).rounded()) }
            return RGB(red: unpremultiplied(bytes[offset]), green: unpremultiplied(bytes[offset + 1]), blue: unpremultiplied(bytes[offset + 2]))
        }

        /// Bounding box of the pixels at least `threshold` opaque, in top-left image coordinates
        /// (what `CGImage.cropping(to:)` takes).
        func opaqueBounds(threshold: UInt8) -> CGRect? {
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                for x in 0..<width where alpha(x: x, y: y) >= threshold {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }

        func averageLuminance(in box: CGRect, alphaThreshold: UInt8) -> Double {
            var sum = 0.0, count = 0
            for y in Int(box.minY)..<Int(box.maxY) {
                for x in Int(box.minX)..<Int(box.maxX) where alpha(x: x, y: y) >= alphaThreshold {
                    let rgb = pixel(x: x, y: y)
                    sum += (0.2126 * Double(rgb.red) + 0.7152 * Double(rgb.green) + 0.0722 * Double(rgb.blue)) / 255
                    count += 1
                }
            }
            return count > 0 ? sum / Double(count) : 0
        }
    }
}
