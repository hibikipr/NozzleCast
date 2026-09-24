import Foundation

/// Full-resolution-enough Live Activity images, kept as files in the shared App Group container
/// instead of inside `PrintActivityAttributes.ContentState`.
///
/// The content state is capped at roughly 4KB serialized, which is why its inline `liveSnapshot`
/// has to be crushed to ~40px — and a 40px frame stretched to the 56pt Lock Screen tile (168px on
/// a 3x screen) is exactly what reads as pixelated; no interpolation filter recovers detail that
/// was never stored. The widget extension shares this App Group, so the notification extension
/// writes a properly sized frame here and puts only its short file name in the content state.
/// The inline `Data` stays as a fallback for when the file is gone or unreadable.
public enum LiveActivityImageStore {
    private static let appGroup = "group.com.victormanuel.NozzleCast"
    private static let directoryName = "LiveActivityImages"
    /// Files kept per printer. More than one so a frame the widget is still rendering from the
    /// previous content state isn't deleted out from under it by the next write.
    static let retainedPerPrinter = 2

    private static var directoryURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Writes `data` as the newest live frame for `printerID` and returns the file name to store in
    /// the content state, or nil if the write failed. Every write gets a new name: an unchanged
    /// name would leave the content state identical, and the system has no reason to re-render.
    public static func saveLiveSnapshot(_ data: Data, printerID: String, now: Date = Date()) -> String? {
        guard let directoryURL else { return nil }
        return save(data, printerID: printerID, in: directoryURL, now: now)
    }

    public static func load(fileName: String) -> Data? {
        guard let directoryURL else { return nil }
        return load(fileName: fileName, in: directoryURL)
    }

    // MARK: - Directory-parameterized core (tested directly)

    static func save(_ data: Data, printerID: String, in directory: URL, now: Date) -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let prefix = filePrefix(for: printerID)
        // Millisecond timestamp so names sort chronologically; the UUID suffix covers two writes
        // landing in the same millisecond.
        let fileName = "\(prefix)\(Int64(now.timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).jpg"
        guard (try? data.write(to: directory.appendingPathComponent(fileName), options: .atomic)) != nil else {
            return nil
        }
        prune(printerID: printerID, in: directory)
        return fileName
    }

    static func load(fileName: String, in directory: URL) -> Data? {
        // The name comes from a decoded content state; refuse anything that could walk out of
        // the directory rather than trusting it.
        guard !fileName.isEmpty, !fileName.contains("/"), !fileName.contains("..") else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(fileName))
    }

    static func prune(printerID: String, in directory: URL) {
        let fm = FileManager.default
        let prefix = filePrefix(for: printerID)
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        let mine = names.filter { $0.hasPrefix(prefix) }.sorted()
        for stale in mine.dropLast(retainedPerPrinter) {
            try? fm.removeItem(at: directory.appendingPathComponent(stale))
        }
    }

    /// printerID is already `PrintActivityAttributes.normalizedID` output (letters/digits only),
    /// but filter again so this never depends on that to stay a safe file-name component.
    private static func filePrefix(for printerID: String) -> String {
        "live-\(printerID.filter { $0.isLetter || $0.isNumber })-"
    }
}
