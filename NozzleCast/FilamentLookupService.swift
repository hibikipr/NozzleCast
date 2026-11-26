import Foundation

/// Cross-references OFD and SpoolmanDB-Community for a scanned barcode or a parsed product
/// title, the same way filament_to_bambuddy's `/api/lookup` and `/api/parse` do. Whichever
/// database resolves first wins on overlapping fields; the other only fills gaps.
enum FilamentLookupService {
    struct Outcome {
        var found: Bool
        var source: String
        var result: ScannedResult
        /// Set when the databases couldn't even be checked (e.g. the first-time index
        /// download failed) - distinct from `found == false`, which means they were checked
        /// and genuinely had no match. Collapsing these together is what makes "couldn't
        /// reach the database" look identical to "not in the database" to the user.
        var lookupError: String?
    }

    private typealias LookupHit = (fields: FilamentDBFields, siblingCodes: [FilamentCodeEntry])

    /// (hit, failed) rather than a plain `LookupHit?` on purpose: `try?` on an
    /// already-Optional-returning throwing function flattens away the outer optional (SE-0230),
    /// so "the lookup threw" and "the lookup ran fine and found nothing" both collapse to the
    /// exact same `nil` - indistinguishable with `try?` alone. An explicit do/catch with a
    /// separate flag is the only way to actually tell those two cases apart.
    private static func attempt(_ body: () async throws -> LookupHit?) async -> (hit: LookupHit?, failed: Bool) {
        do {
            return (try await body(), false)
        } catch {
            return (nil, true)
        }
    }

    static func lookup(barcode: String) async -> Outcome {
        let (code, kind) = FilamentCode.classify(barcode)

        async let ofdAttempt = attempt {
            kind == .gtin ? try await OFDClient.shared.lookup(gtin: code) : try await OFDClient.shared.lookupArticle(code)
        }
        async let smdbAttempt = attempt {
            kind == .gtin ? try await SpoolmanDBCommunityClient.shared.lookup(gtin: code) : try await SpoolmanDBCommunityClient.shared.lookupSKU(code)
        }

        let (ofd, ofdFailed) = await ofdAttempt
        let (smdb, smdbFailed) = await smdbAttempt

        if ofdFailed, smdbFailed {
            return Outcome(
                found: false,
                source: "error",
                result: blankResult(barcode: code),
                lookupError: String(localized: "Couldn't reach the Open Filament Database or SpoolmanDB-Community. Check your connection and try again.")
            )
        }

        if ofd == nil, smdb == nil {
            if ofdFailed {
                return Outcome(
                    found: false,
                    source: "partial-error",
                    result: blankResult(barcode: code),
                    lookupError: String(localized: "No match in SpoolmanDB-Community, and couldn't reach the Open Filament Database. Check your connection and try again.")
                )
            }
            if smdbFailed {
                return Outcome(
                    found: false,
                    source: "partial-error",
                    result: blankResult(barcode: code),
                    lookupError: String(localized: "No match in the Open Filament Database, and couldn't reach SpoolmanDB-Community. Check your connection and try again.")
                )
            }
            return Outcome(found: false, source: "none", result: blankResult(barcode: code), lookupError: nil)
        }

        var merged = FilamentDBFields()
        var source = ""
        var otherTitle: String?

        func merge(_ fields: FilamentDBFields, src: String) {
            if merged.material == nil { merged.material = fields.material }
            if merged.brand == nil { merged.brand = fields.brand }
            if merged.subtype == nil { merged.subtype = fields.subtype }
            if merged.effectType == nil { merged.effectType = fields.effectType }
            if merged.extraColorHexes == nil { merged.extraColorHexes = fields.extraColorHexes }
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

        var result = ScannedResult(
            material: BambuddyMaterials.canonical(merged.material ?? "PLA"),
            colorName: merged.colorName ?? "",
            colorHex: merged.rgba.map { "#" + $0.prefix(6) } ?? "#808080",
            brand: merged.brand ?? "",
            netWeightGrams: merged.labelWeight ?? 1000,
            barcode: kind == .gtin ? code : nil,
            alsoMatches: (otherTitle?.isEmpty == false) ? otherTitle : nil
        )
        result.subtype = merged.subtype
        // The product line names the finish ("Dual Matte PLA", "Glow PLA"); the colour's name can
        // too ("Galaxy Black").
        result.effectType = merged.effectType
            ?? FilamentLabelReader.effect(in: [merged.subtype, merged.colorName].compactMap { $0 }.joined(separator: " "))
        result.extraColorHexes = merged.extraColorHexes ?? []
        result.nozzleTempMin = merged.nozzleTempMin
        result.nozzleTempMax = merged.nozzleTempMax
        result.matchedCode = code
        result.matchedCodeIsSKU = kind == .sku
        return Outcome(found: true, source: source, result: result, lookupError: nil)
    }

    /// Parses free text (a pasted title, or OCR'd label text with no barcodes decoded).
    static func parse(text: String) async -> Outcome {
        await analyze(FilamentLabelReader.Reading(text: text))
    }

    /// Reads a label photo: looks up its codes in order — barcodes, then the SKU — and keeps the
    /// first database hit, falling back to what the label itself says. Either way the label fills
    /// what the database leaves out: the finish (`effect_type`) and a dual-colour roll's colours.
    static func analyze(_ reading: FilamentLabelReader.Reading) async -> Outcome {
        let text = reading.text
        async let ofdBrands = OFDClient.shared.brands()
        async let smdbBrands = SpoolmanDBCommunityClient.shared.brands()
        let extraBrands = Array(Set(await ofdBrands + smdbBrands))
        let parsed = FilamentTitleParser.parse(title: text, extraBrands: extraBrands)
        let labelColor = FilamentLabelReader.color(in: text)
        let labelEffect = FilamentLabelReader.effect(in: text)

        var result = ScannedResult(
            // Many boxes print no material (Panchroma's don't); PLA is the likeliest, and the form shows it.
            material: BambuddyMaterials.canonical(parsed.material ?? "PLA"),
            colorName: labelColor.name ?? parsed.colorName ?? "",
            colorHex: labelColor.partHexes.first.map { "#" + $0 } ?? parsed.rgba.map { "#" + $0.prefix(6) } ?? "#808080",
            brand: parsed.brand ?? "",
            netWeightGrams: parsed.labelWeightGrams ?? 1000,
            barcode: nil,
            alsoMatches: nil
        )
        result.subtype = parsed.subtype
        result.nozzleTempMin = parsed.nozzleTempMin
        result.nozzleTempMax = parsed.nozzleTempMax
        var found = parsed.material != nil || parsed.brand != nil || result.colorName.isEmpty == false
        var source = "parsed"
        var lookupError: String?

        // Barcodes first, then SKUs: the first code a database knows wins. A barcode no database
        // knows (an Amazon stock label) just moves on to the next.
        for code in FilamentLabelReader.codeCandidates(in: reading) {
            let outcome = await lookup(barcode: code)
            if outcome.found {
                let hit = outcome.result
                result.material = hit.material
                result.brand = hit.brand.isEmpty ? result.brand : hit.brand
                if !hit.colorName.isEmpty { result.colorName = hit.colorName }
                if hit.colorHex != "#808080" || labelColor.partHexes.isEmpty { result.colorHex = hit.colorHex }
                // The box's own printed weight wins: a database code can cover several sizes.
                result.netWeightGrams = parsed.labelWeightGrams ?? hit.netWeightGrams
                result.subtype = hit.subtype ?? result.subtype
                result.nozzleTempMin = hit.nozzleTempMin ?? result.nozzleTempMin
                result.nozzleTempMax = hit.nozzleTempMax ?? result.nozzleTempMax
                result.alsoMatches = hit.alsoMatches
                result.barcode = hit.barcode
                result.matchedCode = hit.matchedCode
                result.matchedCodeIsSKU = hit.matchedCodeIsSKU
                result.effectType = hit.effectType
                result.extraColorHexes = hit.extraColorHexes
                // A database name that's product line + colour ("PolyLite™ PLA Pro Blue") when
                // the label names the colour on its own ("COLOR: Blue"): the label's colour, and
                // the rest as the product line.
                if let labelled = labelColor.name, labelColor.isExplicit,
                   let split = FilamentLabelReader.split(productAndColor: hit.colorName, color: labelled, material: hit.material) {
                    result.colorName = split.color
                    if result.subtype == nil { result.subtype = split.productLine }
                }
                source = outcome.source
                found = true
                lookupError = nil
                break
            }
            if let error = outcome.lookupError {
                lookupError = lookupError ?? error
                // Neither database could be reached; every other code would fail the same way.
                if outcome.source == "error" { break }
            }
            if result.barcode == nil {
                let classified = FilamentCode.classify(code)
                if classified.kind == .gtin { result.barcode = classified.code }
            }
        }

        // The label's own words decide the finish when the database's names don't, and a
        // dual- or tri-colour roll gets its parts as extra colours.
        result.effectType = result.effectType ?? labelEffect
        if result.extraColorHexes.isEmpty,
           ["dual-color", "tri-color", "multicolor", "gradient", "rainbow"].contains(result.effectType ?? ""),
           labelColor.partHexes.count >= 2 {
            result.extraColorHexes = labelColor.partHexes
        }

        return Outcome(found: found, source: source, result: result, lookupError: lookupError)
    }

    private static func blankResult(barcode: String? = nil) -> ScannedResult {
        ScannedResult(material: "PLA", colorName: "", colorHex: "#808080", brand: "", netWeightGrams: 1000, barcode: barcode, alsoMatches: nil)
    }
}
