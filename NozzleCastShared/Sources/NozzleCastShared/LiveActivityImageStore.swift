import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A sharp camera frame per printer for the Live Activity, kept as a file in the shared App Group
/// container instead of inside `PrintActivityAttributes.ContentState`.
///
/// The content state is capped at roughly 4KB serialized, so its inline `liveSnapshot` has to be
/// crushed to ~40px — and a 40px frame stretched to the 56pt Lock Screen tile (168px on a 3x
/// screen) is exactly what reads as pixelated; no interpolation filter recovers detail that was
/// never stored.
///
/// Why the widget looks this up by printer ID rather than following a file name carried in the
/// content state (the first attempt at this): the relay drives the activity and every one of its
/// pushes replaces the *whole* content state, so any field the relay doesn't send is wiped on the
/// next progress update. A per-printer file that nobody has to reference survives that.
///
/// Written by whichever on-device process has a full-size frame in hand — the notification
/// extension from Bambuddy's ntfy attachment, the app from its own camera polling.
public enum LiveActivityImageStore {
    private static let appGroup = "group.com.victormanuel.NozzleCast"
    private static let directoryName = "LiveActivityImages"
    private static let knownPrinterIDsKey = "liveActivityKnownPrinterIDs"

    /// Longest edge of the stored frame: covers the 56pt Lock Screen tile at 3x with some margin.
    static let maxPixelSize = 180
    /// Past this age the widget goes back to the relay's inline frame. The inline one is blurry
    /// but refreshed on every relay push; a sharp frame this old would show a print noticeably
    /// behind where it really is. Sharp frames arrive whenever Bambuddy attaches a camera image
    /// to an ntfy push, or every few seconds while the app is open on the printer.
    public static let maxFrameAge: TimeInterval = 30 * 60

    private static var directoryURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Downscales a full-size camera image and stores it as `printerID`'s latest frame.
    /// `printerID` is `PrintActivityAttributes.normalizedID` — the key the widget looks up by.
    public static func saveLatestFrame(sourceImageData: Data, printerID: String) {
        guard let directoryURL, let jpeg = downscaledJPEG(sourceImageData) else { return }
        save(jpeg, printerID: printerID, in: directoryURL)
    }

    /// `printerID`'s latest frame, or nil if there is none or it is older than `maxFrameAge`.
    public static func latestFrame(printerID: String, now: Date = Date()) -> Data? {
        guard let directoryURL else { return nil }
        return latestFrame(printerID: printerID, in: directoryURL, now: now)
    }

    /// Normalized IDs of the printers the app last saw, so the notification extension can tell
    /// which printer a push is about even before (or without) a Live Activity to match against —
    /// Bambuddy's "Print Started" push typically lands before the relay's push-to-start has
    /// created the activity.
    public static var knownPrinterIDs: [String] {
        get { UserDefaults(suiteName: appGroup)?.stringArray(forKey: knownPrinterIDsKey) ?? [] }
        set { UserDefaults(suiteName: appGroup)?.set(newValue, forKey: knownPrinterIDsKey) }
    }

    /// The printers among `candidates` that `haystack` (a normalized push title + body) names.
    /// Drops a match that is only a substring of a longer match, so "p1s" doesn't also claim a
    /// push about "p1s2".
    public static func printerIDs(in haystack: String, candidates: [String]) -> [String] {
        let hits = Set(candidates.filter { !$0.isEmpty && haystack.contains($0) })
        return hits.filter { id in !hits.contains { $0 != id && $0.contains(id) } }.sorted()
    }

    // MARK: - Directory-parameterized core (tested directly)

    static func save(_ jpeg: Data, printerID: String, in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? jpeg.write(to: fileURL(printerID: printerID, in: directory), options: .atomic)
    }

    static func latestFrame(printerID: String, in directory: URL, now: Date) -> Data? {
        let url = fileURL(printerID: printerID, in: directory)
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              now.timeIntervalSince(modified) <= maxFrameAge
        else { return nil }
        return try? Data(contentsOf: url)
    }

    static func downscaledJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Filtered again so this never depends on the caller having normalized the ID to stay a
    /// safe file-name component.
    private static func fileURL(printerID: String, in directory: URL) -> URL {
        directory.appendingPathComponent("live-\(printerID.filter { $0.isLetter || $0.isNumber }).jpg")
    }
}
