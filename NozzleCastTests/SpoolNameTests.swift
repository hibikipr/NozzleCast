import Testing
@testable import NozzleCast

/// A spool is named the way Bambuddy's inventory names it: material plus subtype. The Effect field
/// only changes what the swatch draws.
struct SpoolNameTests {
    static func spool(material: String = "PLA", subtype: String? = nil, effectType: String? = nil) -> Spool {
        Spool(
            id: "1", material: material, colorName: "Foggy Orange", colorHex: "#808080", brand: "Panchroma",
            remainingPercent: 100, netWeightGrams: 1000, location: .storage(name: nil),
            subtype: subtype, effectType: effectType
        )
    }

    @Test func subtypeIsAppendedAndEffectIsNot() {
        #expect(Self.spool(subtype: "Matte Dual Color", effectType: "dual-color").materialWithSubtype == "PLA Matte Dual Color")
    }

    @Test func effectAloneLeavesTheMaterial() {
        #expect(Self.spool(effectType: "glow").materialWithSubtype == "PLA")
    }

    @Test func subtypeThatAlreadyNamesTheMaterialIsNotDoubled() {
        #expect(Self.spool(subtype: "PLA Basic").materialWithSubtype == "PLA Basic")
    }

    @Test func blankSubtypeLeavesTheMaterial() {
        #expect(Self.spool(subtype: "  ").materialWithSubtype == "PLA")
    }
}
