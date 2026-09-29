import ImageIO
import UIKit

/// Decodes image data straight to the size it will be displayed at, off the main actor.
///
/// `UIImage(data:)` defers decoding to first render, which happens on the main thread and at
/// the image's full resolution — a full camera frame decoded every few seconds just to fill a
/// 60pt thumbnail, and full-size notification photos decoded for 52pt list rows. ImageIO's
/// thumbnail path decodes directly to the target size, so the full-resolution bitmap is never
/// allocated at all.
nonisolated enum ImageDownsampling {
    /// `maxPixelSize` is the longest edge in *pixels* (points × screen scale). Nil decodes at full
    /// size, still off the main thread.
    @concurrent
    static func image(from data: Data, maxPixelSize: CGFloat?) async -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }

        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let maxPixelSize {
            options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize
        }
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
