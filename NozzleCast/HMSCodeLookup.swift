import Foundation

/// Looks up a human-readable description for an HMS error code from the Bambu Lab wiki.
/// Bambuddy passes through whatever description the printer itself supplies, which is often
/// nil (as it was for the specific error this was built against), so the wiki is the only
/// source for the description a user would actually recognize. The wiki page's `<title>` tag
/// already reads as "HMS_CODE: <description>. | Bambu Lab Wiki", so that's parsed directly
/// rather than scraping page body markup, which is more likely to change shape over time.
enum HMSCodeLookup {
    private static var cache: [String: String] = [:]

    /// `code` is the dash-separated HMS code, e.g. "0500-0500-0001-0007".
    static func description(forCode code: String) async -> String? {
        if let cached = cache[code] { return cached }

        let underscored = code.replacingOccurrences(of: "-", with: "_")
        guard let url = URL(string: "https://wiki.bambulab.com/en/x1/troubleshooting/hmscode/\(underscored)") else { return nil }

        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8),
              let title = extractTitle(from: html),
              let description = stripWikiTitleChrome(title, code: code)
        else { return nil }

        cache[code] = description
        return description
    }

    static func wikiURL(forCode code: String) -> URL? {
        URL(string: "https://wiki.bambulab.com/en/x1/troubleshooting/hmscode/\(code.replacingOccurrences(of: "-", with: "_"))")
    }

    private static func extractTitle(from html: String) -> String? {
        guard let openRange = html.range(of: "<title>"), let closeRange = html.range(of: "</title>") else { return nil }
        return String(html[openRange.upperBound..<closeRange.lowerBound])
    }

    /// "HMS_0500-0500-0001-0007: MQTT Command verification failed... | Bambu Lab Wiki"
    /// -> "MQTT Command verification failed..."
    private static func stripWikiTitleChrome(_ title: String, code: String) -> String? {
        var text = title
        if let colonRange = text.range(of: ": ") {
            text = String(text[colonRange.upperBound...])
        }
        if let pipeRange = text.range(of: " | ") {
            text = String(text[..<pipeRange.lowerBound])
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A page that doesn't exist for this code still returns 200 with a generic title
        // (no colon to split on, so `text` still contains "HMS_<code>" verbatim) - treat that
        // as no description rather than showing the code back to the user as if it were one.
        return trimmed.isEmpty || trimmed.contains(code) ? nil : trimmed
    }
}
