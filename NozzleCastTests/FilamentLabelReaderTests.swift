import Testing
import UIKit
@testable import NozzleCast

private final class LabelFixtureToken {}

/// Two real Panchroma boxes. Neither prints a material; the Dual Matte one has no EAN at all (only
/// its SKU and an Amazon stock barcode), and the Glow one gives its EAN as text and as a QR code.
struct FilamentLabelReaderTests {
    /// What Vision reads off `Fixtures/label_panchroma_dual_matte.jpg`.
    static let dualMatte = FilamentLabelReader.Reading(
        text: """
        Panchroma
        DUAL
        MATTE
        FOGGY ORANGE
        (GREY-ORANGE)
        SKU
        CA04045
        Batch number
        A7227810126
        Net weight
        1kg
        Diameter
        1.75mm
        A WARNING:
        Lead - Cancer and reproductive harm
        www.P65wamings.ca.gov
        MADE IN CHINA
        X004AR6813
        Panchroma Dual Matte Foggy ... (1.75mm, 1kg)
        NEW
        """,
        barcodes: ["X004AR68I3"]
    )

    /// What Vision reads off `Fixtures/label_panchroma_glow.jpg`.
    static let glow = FilamentLabelReader.Reading(
        text: """
        Panchroma
        GLOW
        BLUE
        EAN: 6938936714712
        SKU: CA02029
        MADE IN CHINA
        X004ASREF3
        Panchroma* Glow Blue (1.75mm. 1kg)
        NEW
        """,
        barcodes: ["X004ASREF3", "6938936714712"]
    )

    // MARK: - Codes: barcodes first, then the SKU

    @Test func glowTriesItsEANBeforeAnythingElse() {
        let codes = FilamentLabelReader.codeCandidates(in: Self.glow)
        #expect(codes.first == "6938936714712")
        #expect(codes.contains("CA02029"))
        #expect(!codes.contains("X004ASREF3"))
    }

    @Test func dualMatteFallsBackToItsSKU() {
        let codes = FilamentLabelReader.codeCandidates(in: Self.dualMatte)
        // The Amazon stock barcode is skipped (no filament database has it); the SKU under its
        // "SKU" heading is tried first.
        #expect(codes.first == "CA04045")
        #expect(!codes.contains("X004AR68I3"))
        #expect(!codes.contains("1.75MM"))
    }

    @Test func skuOnTheSameLineOrTheNext() {
        #expect(FilamentLabelReader.labelledSKUs(in: "SKU: CA02029") == ["CA02029"])
        #expect(FilamentLabelReader.labelledSKUs(in: "SKU\nCA04045\nBatch number") == ["CA04045"])
        #expect(FilamentLabelReader.labelledSKUs(in: "Net weight\n1kg").isEmpty)
    }

    // MARK: - Effect

    @Test func dualMatteIsDualColor() {
        #expect(FilamentLabelReader.effect(in: Self.dualMatte.text) == "dual-color")
    }

    @Test func glowIsGlow() {
        #expect(FilamentLabelReader.effect(in: Self.glow.text) == "glow")
    }

    @Test(arguments: [
        ("PLA Matte Black", "matte"), ("Silk PLA Gold", "silk"), ("Wood PLA", "wood"),
        ("Galaxy Black", "galaxy"), ("Marble White", "marble"), ("Tri Color Silk", "tri-color"),
        ("Glitter PETG", "sparkle"), ("PLA Basic Black", nil),
    ] as [(String, String?)])
    func effects(_ text: String, _ effect: String?) {
        #expect(FilamentLabelReader.effect(in: text) == effect)
    }

    // MARK: - Colour

    @Test func dualMatteColorAndParts() {
        let color = FilamentLabelReader.color(in: Self.dualMatte.text)
        #expect(color.name == "Foggy Orange")
        #expect(color.partHexes == ["808080", "FF7F00"])
    }

    @Test func singleColorLabelHasNoParts() {
        #expect(FilamentLabelReader.color(in: Self.glow.text).partHexes.isEmpty)
    }

    // MARK: - The photos themselves

    static func fixtureImage(_ name: String) throws -> UIImage {
        let bundle = Bundle(for: LabelFixtureToken.self)
        let url = try #require(bundle.url(forResource: name, withExtension: "jpg") ?? bundle.url(forResource: name, withExtension: "jpg", subdirectory: "Fixtures"))
        return try #require(UIImage(contentsOfFile: url.path))
    }

    @Test func glowPhotoYieldsItsEANFromTheQRCode() async throws {
        let reading = await LabelImageReader.read(try Self.fixtureImage("label_panchroma_glow"))
        // On a device Vision also decodes the QR code; the simulator decodes no barcodes, so this
        // relies on the printed "EAN:" line there. Either way the EAN is tried first.
        #expect(FilamentLabelReader.codeCandidates(in: reading).first == "6938936714712")
        #expect(FilamentLabelReader.effect(in: reading.text) == "glow")
    }

    @Test func dualMattePhotoYieldsItsSKU() async throws {
        let reading = await LabelImageReader.read(try Self.fixtureImage("label_panchroma_dual_matte"))
        #expect(FilamentLabelReader.codeCandidates(in: reading).contains("CA04045"))
        #expect(FilamentLabelReader.effect(in: reading.text) == "dual-color")
        #expect(FilamentLabelReader.color(in: reading.text).name == "Foggy Orange")
    }
}

/// Materials are saved as Bambuddy's spool form spells them, and its Effect values are the only
/// ones sent — Bambuddy rejects any other `effect_type`.
struct BambuddyVocabularyTests {
    @Test(arguments: [
        ("PLA", "PLA"), ("petg", "PETG"), ("Asa", "ASA"), ("pla-cf", "PLA-CF"), ("PETG CF", "PETG-CF"),
        ("Nylon", "PA"), ("PA6", "PA"), ("PA12-CF", "PA-CF"), ("PCTG", "PCTG"), ("  TPU ", "TPU"),
    ])
    func canonicalMaterials(_ raw: String, _ expected: String) {
        #expect(BambuddyMaterials.canonical(raw) == expected)
    }

    @Test func materialListMatchesBambuddy() {
        #expect(BambuddyMaterials.common == ["PLA", "PETG", "ABS", "TPU", "ASA", "PC", "PA", "PVA", "HIPS", "PA-CF", "PETG-CF", "PLA-CF"])
    }

    /// `ALLOWED_EFFECT_TYPES` in Bambuddy's `backend/app/schemas/spool.py`.
    static let bambuddyEffects: Set<String> = [
        "sparkle", "wood", "marble", "glow", "matte", "silk", "galaxy", "rainbow", "metal", "translucent",
        "gradient", "dual-color", "tri-color", "multicolor",
    ]

    @Test func effectPickerOffersExactlyBambuddysEffects() {
        #expect(Set(SpoolEffectOptions.all.map(\.value).filter { !$0.isEmpty }) == Self.bambuddyEffects)
    }

    @Test(arguments: [
        "Dual Matte PLA", "Glow", "Silk Gold", "Wood", "Marble", "Galaxy Black", "Glitter", "Metallic Copper",
        "Rainbow", "Gradient", "Tri Color", "Multicolor", "Translucent Red", "Matte Black",
    ])
    func readEffectsAreAllowedByBambuddy(_ text: String) throws {
        let effect = try #require(FilamentLabelReader.effect(in: text))
        #expect(Self.bambuddyEffects.contains(effect))
    }

    @Test(arguments: [("PLA Carbon Fiber Black", "PLA-CF"), ("PETG-CF 1kg", "PETG-CF"), ("Nylon PA12 Natural", "PA"), ("ASA White", "ASA")])
    func parserMaterials(_ title: String, _ expected: String) {
        #expect(FilamentTitleParser.parse(title: title).material.map(BambuddyMaterials.canonical) == expected)
    }
}

/// Three more real boxes: PolyLite PLA Pro (EAN and SKU, in SpoolmanDB only, named "PolyLite™ PLA
/// Pro Blue" there), PolyLite PLA Galaxy Red (SKU only, in OFD) and Panchroma Silk Gold (SKU in no
/// database, so read from the label).
struct MoreBoxesTests {
    @Test func amazonStockCodesAreNeverLookedUp() {
        #expect(FilamentLabelReader.isAmazonStockCode("X002YIDWCP"))
        #expect(FilamentLabelReader.isAmazonStockCode("X004H331ET"))
        #expect(!FilamentLabelReader.isAmazonStockCode("PA07005"))
        #expect(!FilamentLabelReader.isAmazonStockCode("6938936709657"))
        let reading = FilamentLabelReader.Reading(text: "SKU: PA07005\nEAN:6938936709657\nX002YIDWCP", barcodes: ["X002YIDWCP", "6938936709657"])
        #expect(FilamentLabelReader.codeCandidates(in: reading) == ["6938936709657", "PA07005"])
    }

    @Test func colorFieldIsReadAsTheColour() {
        let color = FilamentLabelReader.color(in: "PolyLite™ PLA Pro\nCOLOR: Blue\nDIAMETER: 1.75mm")
        #expect(color.name == "Blue")
        #expect(color.isExplicit)
    }

    @Test func databaseNameSplitsIntoProductLineAndColour() throws {
        let split = try #require(FilamentLabelReader.split(productAndColor: "PolyLite™ PLA Pro Blue", color: "Blue", material: "PLA"))
        #expect(split.color == "Blue")
        #expect(split.productLine == "PolyLite Pro")
        #expect(FilamentLabelReader.split(productAndColor: "Blue", color: "Blue", material: "PLA") == nil)
        #expect(FilamentLabelReader.split(productAndColor: "Sunset Orange", color: "Blue", material: "PLA") == nil)
    }

    @Test func silkGoldReadsFromItsLabel() {
        let text = "Panchroma\nPanchroma™ PLA\nSilk Gold\nSKU: CA03039\nDIAMETER\n1.75mm\nMade In China\n1kg\nX004RPJ5 gD\nPanchroma™ PLA Silk Gold (1 Sem, 3kg)"
        let parsed = FilamentTitleParser.parse(title: text)
        #expect(parsed.brand == "Panchroma")
        #expect(parsed.material == "PLA")
        #expect(parsed.colorName == "Gold")
        #expect(parsed.labelWeightGrams == 1000) // the box's "1kg", not the misread Amazon line
        #expect(FilamentLabelReader.effect(in: text) == "silk")
        #expect(FilamentLabelReader.codeCandidates(in: FilamentLabelReader.Reading(text: text, barcodes: ["X004RPJ58D"])).first == "CA03039")
    }

    @Test func galaxyRedIsGalaxy() {
        #expect(FilamentLabelReader.effect(in: "Creator Special Edition Hedgehog Makes Galaxy Red") == "galaxy")
    }

    @Test(arguments: [
        ("coaxial", 2, "dual-color"), ("coaxial", 3, "tri-color"), ("coaxial", 4, "multicolor"), ("longitudinal", 4, "gradient"),
    ] as [(String, Int, String)])
    func spoolmanDBMulticolour(_ direction: String, _ count: Int, _ effect: String) {
        #expect(SpoolmanDBCommunityClient.effect(finish: nil, pattern: nil, multiColorDirection: direction, colorCount: count, glow: false, translucent: false) == effect)
    }

    @Test func spoolmanDBFinishes() {
        func e(_ finish: String? = nil, _ pattern: String? = nil, glow: Bool = false, translucent: Bool = false) -> String? {
            SpoolmanDBCommunityClient.effect(finish: finish, pattern: pattern, multiColorDirection: nil, colorCount: 0, glow: glow, translucent: translucent)
        }
        #expect(e("matte") == "matte")
        #expect(e("glossy") == nil)
        #expect(e(nil, "sparkle") == "sparkle")
        #expect(e(nil, "marble") == "marble")
        #expect(e("matte", glow: true) == "glow")
        #expect(e(translucent: true) == "translucent")
        #expect(e() == nil)
    }

    @Test(arguments: ["label_polylite_pla_pro_blue", "label_polylite_galaxy_red", "label_panchroma_silk_gold"])
    func photosYieldTheirCodes(_ fixture: String) async throws {
        let reading = await LabelImageReader.read(try FilamentLabelReaderTests.fixtureImage(fixture))
        let codes = FilamentLabelReader.codeCandidates(in: reading)
        let expected = ["label_polylite_pla_pro_blue": "PA07005", "label_polylite_galaxy_red": "PA02106", "label_panchroma_silk_gold": "CA03039"][fixture]!
        #expect(codes.contains(expected))
        #expect(!codes.contains { FilamentLabelReader.isAmazonStockCode($0) })
    }

    @Test func sharedCodePrefersOneKiloOfOneSevenFive() {
        let sizes: [(Double?, Double?)] = [(2.85, 5000), (1.75, 5000), (1.75, 1000), (2.85, 1000), (1.75, 3000)]
        let best = sizes.max { SpoolmanDBCommunityClient.sizeRank(diameter: $0.0, weight: $0.1) < SpoolmanDBCommunityClient.sizeRank(diameter: $1.0, weight: $1.1) }
        #expect(best?.0 == 1.75 && best?.1 == 1000)
    }
}
