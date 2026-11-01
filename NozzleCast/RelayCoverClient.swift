import Foundation
import NozzleCastShared

/// Fetches a printer's cover image (the sliced plate render) from the user's nozzlecast-relay
/// (`GET /cover/:printerID`, see the relay's README "Cover image API").
///
/// The relay asks Bambuddy first and, when Bambuddy has none, reads the job's 3MF straight off the
/// printer. That second source is the only one that finds a cover for an HTTPS-dispatched print
/// (the printer downloads the job from an https:// link into its /cache) or a job name with a "/"
/// — Bambuddy doesn't look for those (maziggy/bambuddy#3382) — so the app asks the relay first
/// whenever one is configured, and Bambuddy directly only when there's no relay or it didn't
/// answer with an image. The relay also keeps each print's cover by Bambuddy archive id, for the
/// print history rows Bambuddy has no thumbnail for (`archiveCoverData`).
enum RelayCoverClient {
    /// The cover as image data, or nil when no relay is configured, the relay has no cover for this
    /// printer's job (404), or it couldn't be reached. `printerName` is the printer's Bambuddy name;
    /// the relay normalizes it the same way `PrintActivityAttributes.normalizedID` does.
    /// `maxPixelSize` lets the relay shrink the render before sending it.
    static func coverImageData(printerName: String, maxPixelSize: CGFloat?) async -> Data? {
        var queryItems: [URLQueryItem] = []
        if let maxPixelSize {
            let size = String(Int(maxPixelSize.rounded(.up)))
            queryItems = [URLQueryItem(name: "width", value: size), URLQueryItem(name: "height", value: size)]
        }
        guard let (status, data) = await fetch(path: ["cover", PrintActivityAttributes.normalizedID(printerName)], queryItems: queryItems, label: printerName),
              status == 200 else { return nil }
        return data
    }

    /// A past print's cover by its Bambuddy archive id (`GET /cover/archive/:id`, relay v1.6.0+): a
    /// square JPEG of the model on its contrast backdrop, for a print history row Bambuddy has no
    /// thumbnail for. Nil when there's no relay, it has none, or it's an older relay (404).
    static func archiveCoverData(archiveID: Int) async -> Data? {
        guard let (status, data) = await fetch(path: ["cover", "archive", String(archiveID)], queryItems: [], label: "archive \(archiveID)"),
              status == 200 else { return nil }
        return data
    }

    enum DisplayCover {
        case image(Data)
        /// The relay predates v1.5.0, which added `bg=auto`, and answered it with a 400.
        case unsupported
        /// No relay, no cover for this job, or no answer.
        case unavailable
    }

    /// The cover composed by the relay for showing as it is (`bg=auto`, relay v1.5.0+): trimmed to
    /// the model, on the backdrop for its brightness (`CoverImageProcessing.backdropDark`/`Light`)
    /// and centred in a `pixelSize` box, so a tile of that shape shows it edge to edge.
    static func displayCoverImageData(printerName: String, pixelSize: CGSize) async -> DisplayCover {
        let queryItems = [
            URLQueryItem(name: "bg", value: "auto"),
            URLQueryItem(name: "width", value: String(Int(pixelSize.width.rounded(.up)))),
            URLQueryItem(name: "height", value: String(Int(pixelSize.height.rounded(.up)))),
        ]
        switch await fetch(path: ["cover", PrintActivityAttributes.normalizedID(printerName)], queryItems: queryItems, label: printerName) {
        case let (200, data)?: return .image(data)
        case (400, _)?: return .unsupported
        default: return .unavailable
        }
    }

    /// `GET` a relay `path` (its components) with `queryItems`: the status and body, or nil when no
    /// relay is configured or it couldn't be reached. `label` names what was asked for in the log.
    private static func fetch(path: [String], queryItems: [URLQueryItem], label: String) async -> (Int, Data)? {
        guard let config = RelayConfigStore.load() else { return nil }
        let url = path.reduce(config.url) { $0.appendingPathComponent($1) }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if !queryItems.isEmpty { components?.queryItems = queryItems }
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(config.authSecret)", forHTTPHeaderField: "Authorization")
        // The relay's first lookup for a job can mean downloading the whole 3MF off the printer
        // over its Wi-Fi; later ones are served from its memory.
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status != 200 {
                NSLog("NCDEBUG relay cover HTTP %d for %@", status, label)
            }
            return (status, data)
        } catch {
            NSLog("NCDEBUG relay cover failed for %@: %@", label, String(describing: error))
            return nil
        }
    }
}
