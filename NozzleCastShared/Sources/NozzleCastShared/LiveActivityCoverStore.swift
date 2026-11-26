import Foundation

/// The sharp cover the app saves for the Live Activity, in the App Group so the widget extension
/// can read it. A Live Activity can't fetch anything itself, and its content-state is capped at
/// ~4KB, so this is how it gets a cover worth looking at; the small `coverImage` in the
/// content-state is only the fallback for when this isn't there yet.
///
/// One cover per printer, replaced by the next print's. It's stored with its job's name and only
/// handed back for that job, so the previous print's cover never shows on the next one.
public enum LiveActivityCoverStore {
    private static let appGroup = "group.com.victormanuel.NozzleCast"

    /// Tests point this at a temporary directory; macOS has no App Group container to use.
    nonisolated(unsafe) static var directoryOverride: URL?

    private static var directory: URL? {
        if let directoryOverride { return directoryOverride }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("LiveActivityCovers", isDirectory: true)
    }

    public struct LoadedCover: Equatable, Sendable {
        public var data: Data
        public var backdropIsLight: Bool?

        public init(data: Data, backdropIsLight: Bool? = nil) {
            self.data = data
            self.backdropIsLight = backdropIsLight
        }
    }

    private struct Metadata: Codable {
        var job: String
        var backdropIsLight: Bool?
        var imageFilename: String?
    }

    public static func save(
        _ data: Data,
        printerID: String,
        jobName: String?,
        backdropIsLight: Bool? = nil,
        directory: URL? = nil
    ) {
        guard let targetDirectory = directory ?? Self.directory else { return }
        let safeID = safePrinterID(printerID)
        let imageFilename = "\(safeID)-\(UUID().uuidString).jpg"
        let metadata = Metadata(
            job: jobKey(jobName),
            backdropIsLight: backdropIsLight,
            imageFilename: imageFilename
        )
        guard let metadataData = try? JSONEncoder().encode(metadata) else { return }

        let imageURL = targetDirectory.appendingPathComponent(imageFilename)
        do {
            try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
            // Write the job-specific image first; if this fails, abort before touching metadata so
            // readers never see new metadata pointing at a missing or stale image.
            try data.write(to: imageURL, options: .atomic)
        } catch {
            return
        }

        do {
            try metadataData.write(to: metadataURL(targetDirectory, safeID), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: imageURL)
            return
        }

        cleanupOldImages(in: targetDirectory, safeID: safeID, keeping: imageFilename)
    }

    /// The saved cover and backdrop hint for this printer's job, or nil if there's none or it's
    /// another job's.
    public static func loadCover(printerID: String, jobName: String?, directory: URL? = nil) -> LoadedCover? {
        guard let targetDirectory = directory ?? Self.directory else { return nil }
        let safeID = safePrinterID(printerID)
        guard let metadataData = try? Data(contentsOf: metadataURL(targetDirectory, safeID)),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: metadataData),
              metadata.job == jobKey(jobName)
        else { return nil }

        let filename = metadata.imageFilename.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "\(safeID).jpg"
        guard !filename.isEmpty,
              let data = try? Data(contentsOf: targetDirectory.appendingPathComponent(filename))
        else { return nil }
        return LoadedCover(data: data, backdropIsLight: metadata.backdropIsLight)
    }

    /// The saved cover for this printer's job, or nil if there's none or it's another job's.
    public static func load(printerID: String, jobName: String?, directory: URL? = nil) -> Data? {
        loadCover(printerID: printerID, jobName: jobName, directory: directory)?.data
    }

    public static func has(printerID: String, jobName: String?, directory: URL? = nil) -> Bool {
        load(printerID: printerID, jobName: jobName, directory: directory) != nil
    }

    /// A job name reduced to what both sides agree on: the app reads the job's file name
    /// ("Part.gcode.3mf") while the relay's content-state carries Bambuddy's job name ("Part").
    static func jobKey(_ jobName: String?) -> String {
        var name = (jobName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for suffix in [".3mf", ".gcode"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        return name
    }

    /// Printer ids are `PrintActivityAttributes.normalizedID`s (letters and digits only already);
    /// filtered the same way regardless before one becomes a file name.
    private static func safePrinterID(_ printerID: String) -> String {
        let safe = printerID.lowercased().filter { $0.isLetter || $0.isNumber }
        return safe.isEmpty ? "printer" : safe
    }

    private static func metadataURL(_ directory: URL, _ safeID: String) -> URL {
        directory.appendingPathComponent("\(safeID).json")
    }

    private static func cleanupOldImages(in directory: URL, safeID: String, keeping currentFilename: String) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let legacyFilename = "\(safeID).jpg"
        let prefix = "\(safeID)-"
        for url in files {
            let name = url.lastPathComponent
            guard name != currentFilename else { continue }
            if name == legacyFilename || (name.hasPrefix(prefix) && name.hasSuffix(".jpg")) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
