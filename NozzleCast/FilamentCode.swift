import Foundation

enum FilamentCodeKind: Equatable, Sendable {
    case gtin
    case sku

    nonisolated static func == (lhs: FilamentCodeKind, rhs: FilamentCodeKind) -> Bool {
        switch (lhs, rhs) {
        case (.gtin, .gtin), (.sku, .sku): true
        default: false
        }
    }
}

/// Fields recovered from a filament database hit (OFD or SpoolmanDB-Community share this shape).
struct FilamentDBFields: Codable {
    var material: String?
    var brand: String?
    var subtype: String?
    var colorName: String?
    var rgba: String?
    var labelWeight: Int?
    var nozzleTempMin: Int?
    var nozzleTempMax: Int?
    var title: String?
    /// Bambuddy's `effect_type`, where the database records the finish (SpoolmanDB does).
    var effectType: String?
    /// "RRGGBB" per colour of a multicolour filament, where the database lists them.
    var extraColorHexes: [String]?
}

/// One barcode/SKU sibling of a matched filament colour (other package sizes, refill code, SKU).
struct FilamentCodeEntry: Codable {
    var code: String
    var kind: String
    var isRefill: Bool
}

nonisolated enum FilamentCode {
    /// Canonical GTIN form for matching: digits only, leading zeros stripped.
    /// Makes a UPC-A (12-digit) and its EAN-13 (leading-zero) form compare equal.
    static func canon(_ barcode: String) -> String {
        let digits = String(barcode.unicodeScalars.filter { (0x30...0x39).contains($0.value) })
        let stripped = digits.drop { $0 == "0" }
        return stripped.isEmpty ? "0" : String(stripped)
    }

    private static func gtinChecksumValid(_ digits: String) -> Bool {
        // Reversed so index 0 is the check digit itself (weight 1); the payload digit
        // immediately to its left (index 1) carries weight 3, alternating from there.
        let chars = Array(digits.reversed()).compactMap { $0.wholeNumberValue }
        guard chars.count == digits.count else { return false }
        var sum = 0
        for (i, d) in chars.enumerated() {
            sum += (i % 2 == 0) ? d : d * 3
        }
        return sum % 10 == 0
    }

    private static func isValidGTIN(_ digits: String) -> Bool {
        guard (8...14).contains(digits.count) else { return false }
        let padded = String(repeating: "0", count: 14 - digits.count) + digits
        return gtinChecksumValid(padded)
    }

    /// Classifies a scanned/typed code as a GTIN (checksummed, standard length) or a
    /// manufacturer SKU/article number. Mirrors filament_to_bambuddy's `_classify_code`.
    static func classify(_ raw: String) -> (code: String, kind: FilamentCodeKind) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDigitSeparatorOnly = !trimmed.isEmpty && trimmed.unicodeScalars.allSatisfy { scalar in
            (0x30...0x39).contains(scalar.value) || scalar == " " || scalar == "-"
        }
        if isDigitSeparatorOnly {
            let digitsOnly = String(trimmed.unicodeScalars.filter { (0x30...0x39).contains($0.value) })
            if isValidGTIN(digitsOnly) {
                return (canon(digitsOnly), .gtin)
            }
        }
        return (trimmed.uppercased(), .sku)
    }

    private static let labelledBarcodeRegex = try! NSRegularExpression(
        pattern: #"(?:EAN|UPC|GTIN|BARCODE)\s*[:#]?\s*(\d[\d\s-]{6,16}\d)"#,
        options: .caseInsensitive
    )
    private static let bareBarcodeRegex = try! NSRegularExpression(
        pattern: #"(?<!\d)(\d{8}|\d{12,14})(?!\d)"#
    )

    /// Pulls a barcode (UPC/EAN/GTIN) out of free text, e.g. label OCR.
    /// Prefers a labelled number ("EAN: 6938936716785") and valid GTIN checksums; falls back to
    /// any bare 8- or 12–14-digit run.
    static func extractBarcode(from text: String) -> String? {
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        var labelledFallback: String?
        for match in labelledBarcodeRegex.matches(in: text, range: fullRange) {
            let raw = ns.substring(with: match.range(at: 1))
            let digits = String(raw.unicodeScalars.filter { (0x30...0x39).contains($0.value) })
            guard (8...14).contains(digits.count) else { continue }
            if isValidGTIN(digits) { return digits }
            if labelledFallback == nil { labelledFallback = digits }
        }

        var bareFallback: String?
        for match in bareBarcodeRegex.matches(in: text, range: fullRange) {
            let digits = ns.substring(with: match.range(at: 1))
            if isValidGTIN(digits) { return digits }
            if bareFallback == nil { bareFallback = digits }
        }

        return labelledFallback ?? bareFallback
    }
}
