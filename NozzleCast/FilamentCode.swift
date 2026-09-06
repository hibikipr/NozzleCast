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
}

/// One barcode/SKU sibling of a matched filament colour (other package sizes, refill code, SKU).
struct FilamentCodeEntry: Codable {
    var code: String
    var kind: String
    var isRefill: Bool
}

enum FilamentCode {
    /// Canonical GTIN form for matching: digits only, leading zeros stripped.
    /// Makes a UPC-A (12-digit) and its EAN-13 (leading-zero) form compare equal.
    static func canon(_ barcode: String) -> String {
        let digits = barcode.filter(\.isNumber)
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

    /// Classifies a scanned/typed code as a GTIN (checksummed, standard length) or a
    /// manufacturer SKU/article number. Mirrors filament_to_bambuddy's `_classify_code`.
    static func classify(_ raw: String) -> (code: String, kind: FilamentCodeKind) {
        let canonical = canon(raw)
        if (8...14).contains(canonical.count) {
            let padded = String(repeating: "0", count: 14 - canonical.count) + canonical
            if gtinChecksumValid(padded) {
                return (canonical, .gtin)
            }
        }
        return (raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), .sku)
    }

    /// Pulls a barcode (UPC/EAN/GTIN) out of free text, e.g. label OCR.
    /// Prefers a labelled number ("EAN: 6938936716785"); falls back to any bare 8–14 digit run.
    static func extractBarcode(from text: String) -> String? {
        if let match = text.range(of: #"(?:EAN|UPC|GTIN|BARCODE)\s*[:#]?\s*(\d[\d\s]{6,16}\d)"#, options: [.regularExpression, .caseInsensitive]) {
            let digits = String(text[match]).filter(\.isNumber)
            if (8...14).contains(digits.count) { return digits }
        }
        if let match = text.range(of: #"(?<!\d)(\d{12,14})(?!\d)"#, options: .regularExpression) {
            let digits = String(text[match])
            if (8...14).contains(digits.count) { return digits }
        }
        return nil
    }
}
