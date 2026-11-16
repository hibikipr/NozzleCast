import Foundation

/// Reads what a photographed filament box or spool label says, beyond `FilamentTitleParser`'s
/// brand/material/colour guesses: the codes worth looking up, in the order to try them, the finish
/// (Bambuddy's `effect_type`), and a dual-colour pair's colours.
///
/// Built around real boxes. Panchroma's, for one, print no material at all ("DUAL / MATTE / FOGGY
/// ORANGE (GREY-ORANGE)"), carry an Amazon stock barcode (Code 128 "X004AR68I3") that no filament
/// database knows, and give the EAN, when they give one, as text or a QR code beside a "SKU:"
/// line. So barcodes are tried first and the SKU after.
enum FilamentLabelReader {
    /// What a label photo yielded: its text, top to bottom, and any barcodes decoded from the image
    /// itself (not the digits printed under them, which are in `text` when legible).
    struct Reading: Equatable {
        var text: String
        var barcodes: [String] = []
    }

    // MARK: - Codes

    /// Codes to look up, best first: decoded barcodes that are GTINs, the EAN/UPC printed on the
    /// label, any other decoded barcode, the SKU printed after a "SKU" label, then any other
    /// SKU-shaped token. Lookups are against on-device indexes, so trying a few extra is cheap.
    static func codeCandidates(in reading: Reading) -> [String] {
        var out: [String] = []
        func add(_ code: String) {
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !out.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
            out.append(trimmed)
        }

        let decoded = reading.barcodes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        for code in decoded where FilamentCode.classify(code).kind == .gtin { add(code) }
        if let printed = FilamentCode.extractBarcode(from: reading.text) { add(printed) }
        for code in decoded { add(code) }
        for sku in labelledSKUs(in: reading.text) { add(sku) }
        for token in skuShapedTokens(in: reading.text) { add(token) }
        return out
    }

    /// Values after "SKU", "Article", "Art. No." or "Item", on the same line or the next (label
    /// layouts put the value under the heading, and OCR then reads them as separate lines).
    static func labelledSKUs(in text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let label = #"^(?:SKU|ARTICLE(?:\s*(?:NO|NUMBER))?|ART\.?\s*NO|ITEM(?:\s*(?:NO|NUMBER))?|MPN|MODEL)\b\.?\s*[:#]?\s*"#
        var out: [String] = []
        for (i, line) in lines.enumerated() {
            guard let match = line.range(of: label, options: [.regularExpression, .caseInsensitive]) else { continue }
            let rest = String(line[match.upperBound...]).trimmingCharacters(in: .whitespaces)
            let value = rest.isEmpty && i + 1 < lines.count ? lines[i + 1] : rest
            if let token = value.split(separator: " ").first.map(String.init), isSKUShaped(token) {
                out.append(token.uppercased())
            }
        }
        return out
    }

    /// Letters and digits together, 5–16 characters, with at least three digits: "CA02029",
    /// "GFA00-B08", "10100". Not a weight, a diameter, a temperature or a URL.
    static func skuShapedTokens(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;()")))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".:")) }
            .filter(isSKUShaped)
            .map { $0.uppercased() }
    }

    private static func isSKUShaped(_ token: String) -> Bool {
        guard (5...16).contains(token.count),
              token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
              token.filter(\.isNumber).count >= 3,
              token.contains(where: \.isLetter)
        else { return false }
        // 1.75mm, 1000g, 220°C-style measurements, and plain words with a number glued on.
        if token.range(of: #"^\d+(?:MM|G|KG|C|F)$"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        return true
    }

    // MARK: - Effect

    /// Bambuddy's effect for a label or product name, or nil. Structure first — a dual-colour
    /// spool is drawn as a split however it's finished, so "Dual Matte" is Dual Color — then
    /// finishes, matte last since it's the plainest. Values match Bambuddy's `effect_type`.
    static func effect(in text: String) -> String? {
        let upper = " " + text.uppercased().replacingOccurrences(of: #"[^A-Z0-9]+"#, with: " ", options: .regularExpression) + " "
        let rules: [(words: [String], effect: String)] = [
            (["MULTICOLOR", "MULTICOLOUR", "MULTI COLOR", "MULTI COLOUR"], "multicolor"),
            (["TRI COLOR", "TRI COLOUR", "TRICOLOR", "TRICOLOUR", "TRIPLE COLOR"], "tri-color"),
            (["DUAL", "DUO", "BICOLOR", "BI COLOR", "TWO COLOR", "COEXTRUSION"], "dual-color"),
            (["GRADIENT"], "gradient"),
            (["RAINBOW"], "rainbow"),
            (["GLOW", "LUMINOUS", "PHOSPHORESCENT"], "glow"),
            (["GALAXY"], "galaxy"),
            (["SPARKLE", "GLITTER", "STARRY", "SHIMMER"], "sparkle"),
            (["SILK"], "silk"),
            (["WOOD"], "wood"),
            (["MARBLE"], "marble"),
            (["METAL", "METALLIC"], "metal"),
            (["TRANSLUCENT", "TRANSPARENT"], "translucent"),
            (["MATTE", "MATT"], "matte"),
        ]
        for rule in rules where rule.words.contains(where: { upper.contains(" \($0) ") }) {
            return rule.effect
        }
        return nil
    }

    // MARK: - Colour

    /// The colour as the label names it and, for a dual- or tri-colour roll, its parts.
    struct LabelColor: Equatable {
        var name: String?
        /// "RRGGBB" per part, in the order the label lists them.
        var partHexes: [String] = []
    }

    /// A pair or triple in brackets — "(GREY-ORANGE)", "(Black/Gold)" — names the parts, and the
    /// line before it, when it holds a colour word, is the colour's own name ("FOGGY ORANGE").
    /// Without one, a plain "Black-Gold" pair is both. Nil name when the label has no colour word.
    static func color(in text: String) -> LabelColor {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for (i, line) in lines.enumerated() {
            let inner = line.trimmingCharacters(in: CharacterSet(charactersIn: "()[] "))
            guard line.hasPrefix("(") || line.hasPrefix("["), let parts = colorParts(inner), parts.count >= 2 else { continue }
            let previous = i > 0 ? lines[i - 1] : ""
            let name = colorWordHex(in: previous) != nil ? titleCased(previous) : parts.map(\.name).joined(separator: "-")
            return LabelColor(name: name, partHexes: parts.map(\.hex))
        }
        for line in lines {
            if let parts = colorParts(line), parts.count >= 2 {
                return LabelColor(name: parts.map(\.name).joined(separator: "-"), partHexes: parts.map(\.hex))
            }
        }
        return LabelColor()
    }

    /// "GREY-ORANGE" → [(Grey, 808080), (Orange, FF7F00)] when every part is a known colour word.
    private static func colorParts(_ text: String) -> [(name: String, hex: String)]? {
        let parts = text.components(separatedBy: CharacterSet(charactersIn: "-/&+")).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, parts.count <= 3 else { return nil }
        var out: [(String, String)] = []
        for part in parts {
            guard let hex = colorHex[part.capitalized] else { return nil }
            out.append((part.capitalized, hex))
        }
        return out
    }

    private static func colorWordHex(in text: String) -> String? {
        for word in text.uppercased().split(whereSeparator: { !$0.isLetter }) {
            if let hex = colorHex[String(word).capitalized] { return hex }
        }
        return nil
    }

    private static func titleCased(_ text: String) -> String {
        text.lowercased().split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The same palette `FilamentTitleParser` uses, for the parts of a multi-colour label.
    static let colorHex: [String: String] = [
        "Black": "000000", "White": "FFFFFF", "Gray": "808080", "Grey": "808080",
        "Silver": "C0C0C0", "Red": "FF0000", "Orange": "FF7F00", "Yellow": "FFFF00",
        "Green": "00A000", "Blue": "0050FF", "Navy": "001F5C", "Cyan": "00FFFF",
        "Teal": "008080", "Purple": "800080", "Violet": "7F00FF", "Pink": "FF69B4",
        "Magenta": "FF00FF", "Brown": "7B3F00", "Beige": "F5F5DC", "Gold": "D4AF37",
        "Bronze": "CD7F32", "Copper": "B87333", "Natural": "EDE6D6", "Clear": "EEEEEE",
        "Olive": "808000", "Lime": "BFFF00", "Maroon": "800000", "Turquoise": "40E0D0",
        "Ivory": "FFFFF0", "Cream": "FFFDD0", "Tan": "D2B48C", "Khaki": "C3B091",
    ]
}

/// Bambuddy's Effect choices (`FILAMENT_EFFECT_OPTIONS`), same order and English labels; "" is None.
/// Shared by the spool editor and the scan review screen.
enum SpoolEffectOptions {
    static let all: [(value: String, label: LocalizedStringResource)] = [
        ("", "None"),
        ("sparkle", "Sparkle"), ("wood", "Wood"), ("marble", "Marble"), ("glow", "Glow"), ("matte", "Matte"),
        ("silk", "Silk"), ("galaxy", "Galaxy"), ("rainbow", "Rainbow"), ("metal", "Metal"), ("translucent", "Translucent"),
        ("gradient", "Gradient"), ("dual-color", "Dual Color"), ("tri-color", "Tri Color"), ("multicolor", "Multicolor"),
    ]
}
