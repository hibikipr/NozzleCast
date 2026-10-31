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

    private struct Metadata: Codable {
        var job: String
    }

    public static func save(_ data: Data, printerID: String, jobName: String?) {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let metadata = try? JSONEncoder().encode(Metadata(job: jobKey(jobName))) else { return }
        // Image first: a reader that found new metadata beside an old image would show the old
        // print's cover under the new job.
        try? data.write(to: fileURL(directory, printerID, "jpg"), options: .atomic)
        try? metadata.write(to: fileURL(directory, printerID, "json"), options: .atomic)
    }

    /// The saved cover for this printer's job, or nil if there's none or it's another job's.
    public static func load(printerID: String, jobName: String?) -> Data? {
        guard let directory,
              let metadataData = try? Data(contentsOf: fileURL(directory, printerID, "json")),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: metadataData),
              metadata.job == jobKey(jobName)
        else { return nil }
        return try? Data(contentsOf: fileURL(directory, printerID, "jpg"))
    }

    public static func has(printerID: String, jobName: String?) -> Bool {
        load(printerID: printerID, jobName: jobName) != nil
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
    private static func fileURL(_ directory: URL, _ printerID: String, _ fileExtension: String) -> URL {
        let safe = printerID.lowercased().filter { $0.isLetter || $0.isNumber }
        return directory.appendingPathComponent("\(safe.isEmpty ? "printer" : safe).\(fileExtension)")
    }
}
