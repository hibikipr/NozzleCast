import Foundation

/// Looks up a human-readable description for an HMS error code from the Bambu Lab wiki.
/// Bambuddy passes through whatever description the printer itself supplies, which is often
/// nil (as it was for the specific error this was built against), so the wiki is the only
/// source for the description a user would actually recognize. The wiki page's `<title>` tag
/// already reads as "HMS_CODE: <description>. | Bambu Lab Wiki", so that's parsed directly
/// rather than scraping page body markup, which is more likely to change shape over time.
actor HMSCodeLookup {
    nonisolated static let shared = HMSCodeLookup()

    private var cache: [String: String?] = [:]
    private var inFlight: [String: Task<(description: String?, shouldCache: Bool), Never>] = [:]

    /// `code` is the dash-separated HMS code, e.g. "0500-0500-0001-0007".
    nonisolated static func description(forCode code: String) async -> String? {
        await shared.description(forCode: code)
    }

    func description(forCode code: String) async -> String? {
        if let cached = cache[code] { return cached }
        if let existing = inFlight[code] {
            return await existing.value.description
        }

        let task = Task<(description: String?, shouldCache: Bool), Never> {
            await Self.fetchDescription(forCode: code)
        }
        inFlight[code] = task
        let outcome = await task.value
        inFlight[code] = nil
        if outcome.shouldCache {
            cache.updateValue(outcome.description, forKey: code)
        }
        return outcome.description
    }

    private static func fetchDescription(forCode code: String) async -> (description: String?, shouldCache: Bool) {
        guard let url = wikiURL(forCode: code) else { return (nil, true) }

        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse
        else { return (nil, false) }

        if http.statusCode == 404 || http.statusCode == 410 {
            return (nil, true)
        }
        guard (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8)
        else { return (nil, false) }

        let description = extractTitle(from: html).flatMap { stripWikiTitleChrome($0, code: code) }
        return (description, true)
    }

    nonisolated static func wikiURL(forCode code: String) -> URL? {
        URL(string: "https://wiki.bambulab.com/en/x1/troubleshooting/hmscode/\(code.replacingOccurrences(of: "-", with: "_"))")
    }

    private nonisolated static let htmlEntityRegex = try! NSRegularExpression(
        pattern: #"&(?:amp|lt|gt|quot|apos|nbsp|#39|#x27);"#,
        options: .caseInsensitive
    )

    private nonisolated static let htmlEntities: [String: String] = [
        "&amp;": "&",
        "&lt;": "<",
        "&gt;": ">",
        "&quot;": "\"",
        "&apos;": "'",
        "&#39;": "'",
        "&#x27;": "'",
        "&nbsp;": " ",
    ]

    nonisolated static func extractTitle(from html: String) -> String? {
        guard let openRange = html.range(of: #"<title[^>]*>"#, options: [.regularExpression, .caseInsensitive]),
              let closeRange = html.range(of: "</title>", options: .caseInsensitive, range: openRange.upperBound..<html.endIndex),
              openRange.upperBound <= closeRange.lowerBound
        else { return nil }
        return decodeHTMLEntities(String(html[openRange.upperBound..<closeRange.lowerBound]))
    }

    private nonisolated static func decodeHTMLEntities(_ text: String) -> String {
        let ns = text as NSString
        let matches = htmlEntityRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            let entity = ns.substring(with: match.range).lowercased()
            if let replacement = htmlEntities[entity] {
                mutable.replaceCharacters(in: match.range, with: replacement)
            }
        }
        return mutable as String
    }

    /// "HMS_0500-0500-0001-0007: MQTT Command verification failed... | Bambu Lab Wiki"
    /// -> "MQTT Command verification failed..."
    nonisolated static func stripWikiTitleChrome(_ title: String, code: String) -> String? {
        var text = title
        if let colonRange = text.range(of: ": ") {
            text = String(text[colonRange.upperBound...])
        }
        if let pipeRange = text.range(of: " | ") {
            text = String(text[..<pipeRange.lowerBound])
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let underscored = code.replacingOccurrences(of: "-", with: "_")
        let lower = trimmed.lowercased()
        // A page that doesn't exist for this code still returns 200 with a generic title
        // (no colon to split on, so `text` still contains "HMS_<code>" verbatim, or a generic
        // 404/not-found page title) - treat that as no description rather than showing it to
        // the user.
        if trimmed.isEmpty
            || trimmed.localizedCaseInsensitiveContains(code)
            || trimmed.localizedCaseInsensitiveContains(underscored)
            || lower.contains("page not found")
            || lower.range(of: #"\b404\b"#, options: .regularExpression) != nil
            || lower == "bambu lab wiki" {
            return nil
        }
        return trimmed
    }
}
