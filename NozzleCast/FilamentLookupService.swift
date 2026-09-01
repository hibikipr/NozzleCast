import Foundation

/// Cross-references OFD and SpoolmanDB-Community for a scanned barcode or a parsed product
/// title, the same way filament_to_bambuddy's `/api/lookup` and `/api/parse` do. Whichever
/// database resolves first wins on overlapping fields; the other only fills gaps.
enum FilamentLookupService {
    struct Outcome {
        var found: Bool
        var source: String
        var result: ScannedResult
    }

    static func lookup(barcode: String) async -> Outcome {
        let (code, kind) = FilamentCode.classify(barcode)

        async let ofdHit = kind == .gtin ? OFDClient.shared.lookup(gtin: code) : OFDClient.shared.lookupArticle(code)
        async let smdbHit = kind == .gtin ? SpoolmanDBCommunityClient.shared.lookup(gtin: code) : SpoolmanDBCommunityClient.shared.lookupSKU(code)

        let ofd = await ofdHit
        let smdb = await smdbHit

        guard ofd != nil || smdb != nil else {
            return Outcome(found: false, source: "none", result: blankResult())
        }

        var merged = FilamentDBFields()
        var source = ""
        var otherTitle: String?

        func merge(_ fields: FilamentDBFields, src: String) {
            if merged.material == nil { merged.material = fields.material }
            if merged.brand == nil { merged.brand = fields.brand }
            if merged.colorName == nil { merged.colorName = fields.colorName }
            if merged.rgba == nil { merged.rgba = fields.rgba }
            if merged.labelWeight == nil { merged.labelWeight = fields.labelWeight }
            if merged.nozzleTempMin == nil { merged.nozzleTempMin = fields.nozzleTempMin }
            if merged.nozzleTempMax == nil { merged.nozzleTempMax = fields.nozzleTempMax }
            if source.isEmpty {
                source = src
                merged.title = fields.title
            } else {
                otherTitle = fields.title
            }
        }

        if let ofd { merge(ofd.fields, src: "ofd") }
        if let smdb { merge(smdb.fields, src: "spoolmandb-community") }

        let result = ScannedResult(
            material: merged.material.flatMap(FilamentMaterial.init(rawValue:)) ?? .from(bambuddyMaterial: merged.material ?? "PLA"),
            colorName: merged.colorName ?? "",
            colorHex: merged.rgba.map { "#" + $0.prefix(6) } ?? "#808080",
            brand: merged.brand ?? "",
            netWeightGrams: merged.labelWeight ?? 1000,
            alsoMatches: (otherTitle?.isEmpty == false) ? otherTitle : nil
        )
        return Outcome(found: true, source: source, result: result)
    }

    /// Parses free text (OCR'd label or a pasted title) into best-effort fields, and — if a
    /// barcode is embedded in the text — resolves it and lets authoritative DB data override
    /// the heuristic guesses, the same precedence `/api/parse` uses.
    static func parse(text: String) async -> Outcome {
        let extraBrands = await OFDClient.shared.brands()
        let parsed = FilamentTitleParser.parse(title: text, extraBrands: extraBrands)

        var result = ScannedResult(
            material: parsed.material.flatMap(FilamentMaterial.init(rawValue:)) ?? .pla,
            colorName: parsed.colorName ?? "",
            colorHex: parsed.rgba.map { "#" + $0.prefix(6) } ?? "#808080",
            brand: parsed.brand ?? "",
            netWeightGrams: parsed.labelWeightGrams ?? 1000,
            alsoMatches: nil
        )
        var found = parsed.material != nil || parsed.brand != nil || parsed.colorName != nil
        var source = "parsed"

        if let barcode = FilamentCode.extractBarcode(from: text) {
            let barcodeOutcome = await lookup(barcode: barcode)
            if barcodeOutcome.found {
                result = barcodeOutcome.result
                source = barcodeOutcome.source
                found = true
            }
        }

        return Outcome(found: found, source: source, result: result)
    }

    private static func blankResult() -> ScannedResult {
        ScannedResult(material: .pla, colorName: "", colorHex: "#808080", brand: "", netWeightGrams: 1000, alsoMatches: nil)
    }
}
