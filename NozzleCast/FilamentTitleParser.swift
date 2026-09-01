import Foundation

/// Best-effort heuristics that turn a product title or OCR'd label text (e.g. "SUNLU PLA+
/// 1.75mm Black 1KG") into filament fields. Ported from filament_to_bambuddy's
/// `filament_parse.py`. Everything here is a guess — the review screen always lets the
/// user correct it.
enum FilamentTitleParser {
    struct ParsedFields {
        var brand: String?
        var material: String?
        var subtype: String?
        var colorName: String?
        var rgba: String?
        var nozzleTempMin: Int?
        var nozzleTempMax: Int?
        var labelWeightGrams: Int?
    }

    static let knownBrands = [
        "Bambu Lab", "Polymaker", "Prusament", "Prusa", "Fillamentum", "MatterHackers",
        "Protopasta", "ColorFabb", "Overture", "Hatchbox", "Inland", "Creality",
        "Elegoo", "Anycubic", "Geeetech", "Eryone", "Amolen", "Duramic", "Sunlu",
        "eSUN", "Jayo", "Atomic", "Spectrum", "3DJake", "Comgrow", "Tinmorry",
        "Kingroon", "Flashforge", "Ziro", "Novamaker", "GST3D", "Iemai",
    ]

    // Order matters: most specific / longest token first (PETG before PET, PLA+ before PLA).
    private static let baseMaterials: [(String, String)] = [
        ("PCTG", "PCTG"), ("PETG", "PETG"), ("PET-G", "PETG"), ("PET G", "PETG"),
        ("PLA+", "PLA"), ("PLA PLUS", "PLA"), ("PLA", "PLA"),
        ("ABS+", "ABS"), ("ABS", "ABS"), ("ASA", "ASA"),
        ("TPU", "TPU"), ("TPE", "TPE"),
        ("NYLON", "Nylon"), ("PA12", "Nylon"), ("PA6", "Nylon"), ("PA", "Nylon"),
        ("HIPS", "HIPS"), ("PVA", "PVA"), ("PC", "PC"),
    ]

    private static let subtypeHints: [(String, String)] = [
        ("CARBON FIBER", "Carbon Fiber"), ("CARBON FIBRE", "Carbon Fiber"),
        ("CARBON", "Carbon Fiber"), ("GLOW IN THE DARK", "Glow"), ("GLOW", "Glow"),
        ("SILK", "Silk"), ("MATTE", "Matte"), ("MARBLE", "Marble"), ("WOOD", "Wood"),
        ("METAL", "Metal"), ("RAINBOW", "Rainbow"), ("GRADIENT", "Gradient"),
        ("DUAL COLOR", "Dual Color"), ("DUAL COLOUR", "Dual Color"), ("DUAL", "Dual Color"),
        ("TRI COLOR", "Tri Color"), ("TRI COLOUR", "Tri Color"),
        ("HIGH SPEED", "High Speed"), ("HYPER", "High Speed"), ("TOUGH", "Tough"),
        ("GALAXY", "Galaxy"), ("SPARKLE", "Sparkle"), ("GLITTER", "Glitter"),
        ("LUMINOUS", "Luminous"), ("FLUORESCENT", "Fluorescent"),
        ("TRANSLUCENT", "Translucent"), ("TRANSPARENT", "Transparent"),
        ("PLUS", "Plus"),
    ]

    private static let colorHex: [String: String] = [
        "Black": "000000", "White": "FFFFFF", "Gray": "808080", "Grey": "808080",
        "Silver": "C0C0C0", "Red": "FF0000", "Orange": "FF7F00", "Yellow": "FFFF00",
        "Green": "00A000", "Blue": "0050FF", "Navy": "001F5C", "Cyan": "00FFFF",
        "Teal": "008080", "Purple": "800080", "Violet": "7F00FF", "Pink": "FF69B4",
        "Magenta": "FF00FF", "Brown": "7B3F00", "Beige": "F5F5DC", "Gold": "D4AF37",
        "Bronze": "CD7F32", "Copper": "B87333", "Natural": "EDE6D6", "Clear": "EEEEEE",
        "Transparent": "EEEEEE", "Skin": "FFCDA0", "Olive": "808000", "Lime": "BFFF00",
        "Maroon": "800000", "Turquoise": "40E0D0", "Ivory": "FFFFF0", "Cream": "FFFDD0",
        "Tan": "D2B48C", "Khaki": "C3B091",
    ]
    private static let colorWords = colorHex.keys.sorted { $0.count > $1.count }

    private static func findBrand(_ upper: String, extraBrands: [String]) -> String? {
        var seen = Set<String>()
        var uniq: [String] = []
        for b in knownBrands + extraBrands {
            let trimmed = b.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !seen.contains(trimmed.uppercased()) else { continue }
            seen.insert(trimmed.uppercased())
            uniq.append(trimmed)
        }
        uniq.sort { $0.count > $1.count }
        if let hit = uniq.first(where: { $0.count >= 4 && upper.contains($0.uppercased()) }) { return hit }
        return uniq.first { upper.contains($0.uppercased()) }
    }

    private static func findMaterial(_ upper: String) -> (material: String?, plusSubtype: String?) {
        for (token, canonical) in baseMaterials {
            let pattern = "(?<![A-Z])" + NSRegularExpression.escapedPattern(for: token) + "(?![A-Z])"
            if upper.range(of: pattern, options: .regularExpression) != nil {
                let sub = (token.hasSuffix("+") || token.hasSuffix("PLUS")) ? "Plus" : nil
                return (canonical, sub)
            }
        }
        return (nil, nil)
    }

    private static func findSubtypes(_ upper: String) -> [String] {
        var found: [String] = []
        for (token, canonical) in subtypeHints {
            if upper.contains(token), !found.contains(canonical) { found.append(canonical) }
        }
        return found
    }

    private static func findColor(_ text: String) -> (name: String?, rgba: String?) {
        let escaped = colorWords.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        if let match = text.range(of: "\\b(\(escaped))\\s*[-/]\\s*(\(escaped))\\b", options: [.regularExpression, .caseInsensitive]) {
            let parts = String(text[match]).components(separatedBy: CharacterSet(charactersIn: "-/")).map { $0.trimmingCharacters(in: .whitespaces).capitalized }
            if parts.count == 2, let rgba = colorHex[parts[0]] {
                return ("\(parts[0])-\(parts[1])", rgba + "FF")
            }
        }
        for word in colorWords {
            if text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: [.regularExpression, .caseInsensitive]) != nil {
                return (word, colorHex[word]! + "FF")
            }
        }
        return (nil, nil)
    }

    private static func findHex(_ text: String) -> String? {
        guard let match = text.range(of: "#([0-9A-Fa-f]{6})\\b", options: .regularExpression) else { return nil }
        return String(text[match]).dropFirst().uppercased() + "FF"
    }

    private static func findNozzleTemps(_ text: String) -> (Int, Int)? {
        let ns = text as NSString
        if let regex = try? NSRegularExpression(pattern: "(\\d{2,3})\\s*[-–~]\\s*(\\d{2,3})\\s*°?\\s*[cC]\\b") {
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let lo = Int(ns.substring(with: m.range(at: 1))), let hi = Int(ns.substring(with: m.range(at: 2))) else { continue }
                if lo >= 140, hi <= 360, lo <= hi { return (lo, hi) }
            }
        }
        if let regex = try? NSRegularExpression(pattern: "(\\d{2,3})\\s*°?\\s*[cC]\\b") {
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let t = Int(ns.substring(with: m.range(at: 1))) else { continue }
                if (140...360).contains(t) { return (t, t) }
            }
        }
        if let regex = try? NSRegularExpression(pattern: "(?<!\\d)(\\d{2,3})\\s*[-–~]\\s*(\\d{2,3})(?!\\d)") {
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let lo = Int(ns.substring(with: m.range(at: 1))), let hi = Int(ns.substring(with: m.range(at: 2))) else { continue }
                if lo >= 150, hi <= 320, lo <= hi, (hi - lo) >= 5, (hi - lo) <= 120 { return (lo, hi) }
            }
        }
        return nil
    }

    private static func findWeightGrams(_ text: String) -> Int? {
        if let match = text.range(of: "(\\d+(?:\\.\\d+)?)\\s*(kg|kgs|kilograms?)\\b", options: [.regularExpression, .caseInsensitive]) {
            let numStr = String(text[match]).prefix { $0.isNumber || $0 == "." }
            if let n = Double(numStr) { return Int((n * 1000).rounded()) }
        }
        if let match = text.range(of: "(\\d{3,5})\\s*(g|grams?)\\b", options: [.regularExpression, .caseInsensitive]) {
            let numStr = String(text[match]).prefix { $0.isNumber }
            if let n = Int(numStr) { return n }
        }
        return nil
    }

    static func parse(title: String, extraBrands: [String] = []) -> ParsedFields {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ParsedFields() }
        let upper = text.uppercased()
        var out = ParsedFields()

        out.brand = findBrand(upper, extraBrands: extraBrands)

        let (material, plusSub) = findMaterial(upper)
        out.material = material

        var subtypes = findSubtypes(upper)
        if let plusSub, !subtypes.contains(plusSub) { subtypes.insert(plusSub, at: 0) }
        if !subtypes.isEmpty { out.subtype = subtypes.joined(separator: " ") }

        let (colorName, colorRgba) = findColor(text)
        out.colorName = colorName
        out.rgba = colorRgba
        if let hexRgba = findHex(text) { out.rgba = hexRgba }

        if let temps = findNozzleTemps(text) {
            out.nozzleTempMin = temps.0
            out.nozzleTempMax = temps.1
        }

        out.labelWeightGrams = findWeightGrams(text)

        return out
    }
}
