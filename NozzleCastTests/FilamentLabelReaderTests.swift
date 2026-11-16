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
        #expect(codes.firstIndex(of: "X004ASREF3")! < codes.firstIndex(of: "CA02029")!)
    }

    @Test func dualMatteFallsBackToItsSKU() {
        let codes = FilamentLabelReader.codeCandidates(in: Self.dualMatte)
        // The Amazon stock barcode is tried (and misses), then the SKU under its "SKU" heading.
        #expect(codes.first == "X004AR68I3")
        #expect(codes[1] == "CA04045")
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
