import Foundation
import NozzleCastShared

/// Fetches a printer's cover image (the sliced plate render) from the user's nozzlecast-relay
/// (`GET /cover/:printerID`, see the relay's README "Cover image API").
///
/// The relay asks Bambuddy first and, when Bambuddy has none, reads the job's 3MF straight off the
/// printer. That second source is the only one that finds a cover for a cloud print (Bambu Handy,
/// MakerWorld) or a job name with a "/" — Bambuddy doesn't look for those (maziggy/bambuddy#3382,
/// closed as out of scope) — so the app asks the relay first whenever one is configured, and
/// Bambuddy directly only when there's no relay or it didn't answer with an image.
enum RelayCoverClient {
    /// The cover as image data, or nil when no relay is configured, the relay has no cover for this
    /// printer's job (404), or it couldn't be reached. `printerName` is the printer's Bambuddy name;
    /// the relay normalizes it the same way `PrintActivityAttributes.normalizedID` does.
    /// `maxPixelSize` lets the relay shrink the render before sending it.
    static func coverImageData(printerName: String, maxPixelSize: CGFloat?) async -> Data? {
        guard let config = RelayConfigStore.load() else { return nil }
        var components = URLComponents(
            url: config.url.appendingPathComponent("cover").appendingPathComponent(PrintActivityAttributes.normalizedID(printerName)),
            resolvingAgainstBaseURL: false
        )
        if let maxPixelSize {
            let size = String(Int(maxPixelSize.rounded(.up)))
            components?.queryItems = [URLQueryItem(name: "width", value: size), URLQueryItem(name: "height", value: size)]
        }
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(config.authSecret)", forHTTPHeaderField: "Authorization")
        // The relay's first lookup for a job can mean downloading the whole 3MF off the printer
        // over its Wi-Fi; later ones are served from its memory.
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                NSLog("NCDEBUG relay cover HTTP %d for printer=%@", status, printerName)
                return nil
            }
            return data
        } catch {
            NSLog("NCDEBUG relay cover failed for printer=%@: %@", printerName, String(describing: error))
            return nil
        }
    }
}
