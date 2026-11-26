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
        "Kingroon", "Flashforge", "Ziro", "Novamaker", "GST3D", "Iemai", "Panchroma",
    ]

    // Order matters: most specific / longest token first (PETG before PET, PLA+ before PLA).
    private static let baseMaterials: [(String, String)] = [
        ("PCTG", "PCTG"), ("PETG", "PETG"), ("PET-G", "PETG"), ("PET G", "PETG"),
        ("PLA+", "PLA"), ("PLA PLUS", "PLA"), ("PLA", "PLA"),
        ("ABS+", "ABS"), ("ABS", "ABS"), ("ASA", "ASA"),
        ("TPU", "TPU"), ("TPE", "TPE"),
        ("NYLON", "PA"), ("PA12", "PA"), ("PA6", "PA"), ("PA", "PA"),
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
    private static let clarityModifiers: Set<String> = ["Transparent", "Translucent", "Clear", "Natural"]
    private static let chromaticWords = colorWords.filter { !clarityModifiers.contains($0) }
    private static let clarityColorWords = colorWords.filter { clarityModifiers.contains($0) }

    private static let knownBrandMap: [String: String] = {
        var map: [String: String] = [:]
        for brand in knownBrands {
            let trimmed = brand.trimmingCharacters(in: .whitespaces)
            let key = trimmed.uppercased()
            if !trimmed.isEmpty, map[key] == nil { map[key] = trimmed }
        }
        return map
    }()

    private static let knownBrandRegex: NSRegularExpression? = buildBrandRegex(for: knownBrands)

    private static func buildBrandRegex(for brands: [String]) -> NSRegularExpression? {
        let patterns = brands
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
        guard !patterns.isEmpty else { return nil }
        return try? NSRegularExpression(
            pattern: "(?<![A-Za-z0-9])(?:" + patterns.joined(separator: "|") + ")(?![A-Za-z0-9])",
            options: .caseInsensitive
        )
    }

    private static let materialMatchers: [(regex: NSRegularExpression, canonical: String, isPlus: Bool)] = baseMaterials.compactMap { token, canonical in
        let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: token) + "(?![A-Za-z0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let isPlus = token.hasSuffix("+") || token.hasSuffix("PLUS")
        return (regex, canonical, isPlus)
    }

    private static let subtypeMatchers: [(regex: NSRegularExpression, canonical: String)] = subtypeHints.compactMap { token, canonical in
        let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: token) + "(?![A-Za-z0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        return (regex, canonical)
    }

    private static let cfRegex = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9])CF(?![A-Za-z0-9])"#, options: .caseInsensitive)

    private static let dualColorRegex: NSRegularExpression = {
        let escaped = colorWords.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return try! NSRegularExpression(pattern: "\\b(\(escaped))\\s*[-/]\\s*(\(escaped))\\b", options: .caseInsensitive)
    }()

    private static let chromaticColorMatchers: [(word: String, regex: NSRegularExpression, hex: String)] = chromaticWords.compactMap { word in
        guard let regex = try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: .caseInsensitive),
              let hex = colorHex[word]
        else { return nil }
        return (word, regex, hex)
    }

    private static let clarityColorMatchers: [(word: String, regex: NSRegularExpression, hex: String)] = clarityColorWords.compactMap { word in
        guard let regex = try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: .caseInsensitive),
              let hex = colorHex[word]
        else { return nil }
        return (word, regex, hex)
    }

    private static let clarityPrefixRegex = try! NSRegularExpression(
        pattern: #"(?:^|[^A-Za-z0-9])(Transparent|Translucent|Clear|Natural)\s+$"#,
        options: .caseInsensitive
    )

    private static let hexRegex = try! NSRegularExpression(pattern: #"#([0-9A-Fa-f]{6})\b"#)
    private static let tempRangeWithCRegex = try! NSRegularExpression(pattern: #"(\d{2,3})\s*[-–~]\s*(\d{2,3})\s*°?\s*[cC]\b"#)
    private static let tempSingleWithCRegex = try! NSRegularExpression(pattern: #"(\d{2,3})\s*°?\s*[cC]\b"#)
    private static let tempBareRangeRegex = try! NSRegularExpression(pattern: #"(?<!\d)(\d{2,3})\s*[-–~]\s*(\d{2,3})(?!\d)"#)
    private static let weightKgRegex = try! NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*(kg|kgs|kilograms?)\b"#, options: .caseInsensitive)
    private static let weightGRegex = try! NSRegularExpression(pattern: #"(\d{3,5})\s*(g|grams?)\b"#, options: .caseInsensitive)

    private static func findBrand(_ text: String, extraBrands: [String]) -> String? {
        let brandMap: [String: String]
        let regex: NSRegularExpression?
        if extraBrands.isEmpty {
            brandMap = knownBrandMap
            regex = knownBrandRegex
        } else {
            var map = knownBrandMap
            var uniq: [String] = Array(knownBrandMap.values)
            for b in extraBrands {
                let trimmed = b.trimmingCharacters(in: .whitespaces)
                let key = trimmed.uppercased()
                guard !trimmed.isEmpty, map[key] == nil else { continue }
                map[key] = trimmed
                uniq.append(trimmed)
            }
            brandMap = map
            regex = buildBrandRegex(for: uniq)
        }
        guard let regex else { return nil }

        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var bestLong: String?
        var bestShort: String?
        for m in matches {
            let matched = ns.substring(with: m.range).uppercased()
            guard let canonical = brandMap[matched] else { continue }
            if canonical.count >= 4 {
                if bestLong == nil || canonical.count > bestLong!.count { bestLong = canonical }
            } else {
                if bestShort == nil || canonical.count > bestShort!.count { bestShort = canonical }
            }
        }
        return bestLong ?? bestShort
    }

    private static func findMaterial(_ text: String) -> (material: String?, plusSubtype: String?) {
        let range = NSRange(location: 0, length: (text as NSString).length)
        for matcher in materialMatchers {
            if matcher.regex.firstMatch(in: text, range: range) != nil {
                return (matcher.canonical, matcher.isPlus ? "Plus" : nil)
            }
        }
        return (nil, nil)
    }

    private static func findSubtypes(_ text: String) -> [String] {
        let range = NSRange(location: 0, length: (text as NSString).length)
        var found: [String] = []
        for matcher in subtypeMatchers {
            if matcher.regex.firstMatch(in: text, range: range) != nil, !found.contains(matcher.canonical) {
                found.append(matcher.canonical)
            }
        }
        return found
    }

    private static func findColor(_ text: String) -> (name: String?, rgba: String?) {
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        if let match = dualColorRegex.firstMatch(in: text, range: fullRange) {
            let raw = ns.substring(with: match.range)
            let parts = raw.components(separatedBy: CharacterSet(charactersIn: "-/"))
                .map { $0.trimmingCharacters(in: .whitespaces).capitalized }
            if parts.count == 2, let firstHex = colorHex[parts[0]], let secondHex = colorHex[parts[1]] {
                let hex = clarityModifiers.contains(parts[0]) ? secondHex : firstHex
                return ("\(parts[0])-\(parts[1])", hex + "FF")
            }
        }

        for matcher in chromaticColorMatchers {
            guard let match = matcher.regex.firstMatch(in: text, range: fullRange) else { continue }
            if match.range.location > 0 {
                let prefix = ns.substring(to: match.range.location)
                let prefixNS = prefix as NSString
                if let modMatch = clarityPrefixRegex.firstMatch(in: prefix, range: NSRange(location: 0, length: prefixNS.length)) {
                    let modifier = prefixNS.substring(with: modMatch.range(at: 1)).capitalized
                    return ("\(modifier) \(matcher.word)", matcher.hex + "FF")
                }
            }
            return (matcher.word, matcher.hex + "FF")
        }

        for matcher in clarityColorMatchers {
            if matcher.regex.firstMatch(in: text, range: fullRange) != nil {
                return (matcher.word, matcher.hex + "FF")
            }
        }

        return (nil, nil)
    }

    private static func findHex(_ text: String) -> String? {
        let ns = text as NSString
        guard let match = hexRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range(at: 1)).uppercased() + "FF"
    }

    private static func findNozzleTemps(_ text: String) -> (Int, Int)? {
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        for m in tempRangeWithCRegex.matches(in: text, range: fullRange) {
            guard let lo = Int(ns.substring(with: m.range(at: 1))), let hi = Int(ns.substring(with: m.range(at: 2))) else { continue }
            if lo >= 140, hi <= 360, lo <= hi { return (lo, hi) }
        }
        for m in tempSingleWithCRegex.matches(in: text, range: fullRange) {
            guard let t = Int(ns.substring(with: m.range(at: 1))) else { continue }
            if (140...360).contains(t) { return (t, t) }
        }
        for m in tempBareRangeRegex.matches(in: text, range: fullRange) {
            guard let lo = Int(ns.substring(with: m.range(at: 1))), let hi = Int(ns.substring(with: m.range(at: 2))) else { continue }
            if lo >= 150, hi <= 320, lo <= hi, (hi - lo) >= 5, (hi - lo) <= 120 { return (lo, hi) }
        }
        return nil
    }

    private static func findWeightGrams(_ text: String) -> Int? {
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        if let m = weightKgRegex.firstMatch(in: text, range: fullRange),
           let n = Double(ns.substring(with: m.range(at: 1))) {
            return Int((n * 1000).rounded())
        }
        if let m = weightGRegex.firstMatch(in: text, range: fullRange),
           let n = Int(ns.substring(with: m.range(at: 1))) {
            return n
        }
        return nil
    }

    static func parse(title: String, extraBrands: [String] = []) -> ParsedFields {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ParsedFields() }
        var out = ParsedFields()

        out.brand = findBrand(text, extraBrands: extraBrands)

        let (material, plusSub) = findMaterial(text)
        out.material = material

        var subtypes = findSubtypes(text)
        // Carbon-fibre PLA/PETG/PA is its own material in Bambuddy's list (PLA-CF, PETG-CF, PA-CF).
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        if let base = out.material, ["PLA", "PETG", "PA"].contains(base),
           subtypes.contains("Carbon Fiber") || cfRegex.firstMatch(in: text, range: fullRange) != nil {
            out.material = base + "-CF"
        }
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
