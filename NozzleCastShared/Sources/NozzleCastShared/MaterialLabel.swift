import Foundation

/// Shortens a filament's material name for surfaces that have to fit it into a fixed, small box.
///
/// `AMSTraySnapshot.materialLabel` is whatever the printer or the spool record says, verbatim —
/// Bambu's raw `tray_type` or a user-entered spool material (see `AppStore.makeAMSSnapshots`).
/// Most values are already short ("PLA", "PETG-CF"), but the support filaments are not:
/// "Support for PLA" is more than twice the width of its neighbours in the same row. In the AMS
/// widget that made the *only* label carrying real information — every other slot in the row said
/// "PLA" — the smallest text on screen.
///
/// Deliberately narrow. This shortens the one family of names that is actually verbose and leaves
/// everything else exactly as the printer reported it; inventing abbreviations for material names
/// the user recognises would trade one legibility problem for a comprehension one.
public enum MaterialLabel {
    private static let supportPrefixes = ["support for ", "support:"]

    /// Returns nil for nil, empty, or whitespace-only input, so callers draw no label at all
    /// rather than an empty one.
    public static func short(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }

        let lowered = collapsed.lowercased()
        for prefix in supportPrefixes where lowered.hasPrefix(prefix) {
            let base = collapsed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            // "Support for PLA" -> "PLA SUP": the base material stays leading, so the label still
            // scans down a column alongside the plain "PLA" of its neighbours, with the
            // distinguishing token appended rather than buried in a prefix.
            return base.isEmpty ? "SUP" : "\(base) SUP"
        }
        // A bare "Support" with no paired material named.
        if lowered == "support" { return "SUP" }

        return collapsed
    }
}
