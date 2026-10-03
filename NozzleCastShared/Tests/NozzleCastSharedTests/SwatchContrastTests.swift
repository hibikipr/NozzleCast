import XCTest
@testable import NozzleCastShared

/// The AMS widget draws a material label directly on the filament swatch, with no backing band —
/// a band would hide the one thing the widget exists to show. So the label's colour has to be
/// derived from whatever the swatch is actually displaying.
final class SwatchContrastTests: XCTestCase {

    func testDarkSwatchGetsLightText() {
        XCTAssertEqual(SwatchContrast.preferredForeground(colorHex: "1B2A6B"), .light)
    }

    func testLightSwatchGetsDarkText() {
        XCTAssertEqual(SwatchContrast.preferredForeground(colorHex: "F2F2F2"), .dark)
    }

    func testPureBlackGetsLightText() {
        XCTAssertEqual(SwatchContrast.preferredForeground(colorHex: "000000"), .light)
    }

    func testPureWhiteGetsDarkText() {
        XCTAssertEqual(SwatchContrast.preferredForeground(colorHex: "FFFFFF"), .dark)
    }

    /// Luminance is not the mean of the channels: pure green is far brighter to the eye than
    /// pure blue at the same numeric value, and a naive average would call both mid-grey.
    func testGreenAndBlueOfEqualChannelValueDisagree() {
        XCTAssertEqual(SwatchContrast.preferredForeground(colorHex: "00FF00"), .dark)
        XCTAssertEqual(SwatchContrast.preferredForeground(colorHex: "0000FF"), .light)
    }

    /// `FilamentSwatchView` draws a checkerboard base *unconditionally* and composites the colour
    /// over it, so a translucent spool reads as genuinely clear rather than a muddy tint. That
    /// checkerboard is light (0.96/0.59), which means alpha pulls a swatch toward light — not
    /// toward the near-black widget canvas the pill happens to sit on. Getting this backwards
    /// puts white text on a pale checkerboard.
    func testTranslucentSwatchCompositesTowardTheLightCheckerboard() {
        XCTAssertEqual(SwatchContrast.preferredForeground(colorHex: "1B2A6B", alpha: 1), .light)
        XCTAssertEqual(SwatchContrast.preferredForeground(colorHex: "1B2A6B", alpha: 0.2), .dark)
    }

    /// A fully transparent colour layer leaves the bare checkerboard showing.
    func testFullyTransparentSwatchIsJustTheCheckerboard() {
        XCTAssertEqual(SwatchContrast.preferredForeground(colorHex: "000000", alpha: 0), .dark)
    }

    /// An opaque colour hides the checkerboard entirely, so alpha 1 must not drag anything light.
    func testOpaqueDarkSwatchIsUnaffectedByTheCheckerboard() {
        XCTAssertEqual(SwatchContrast.preferredForeground(colorHex: "000000", alpha: 1), .light)
    }

    /// A multi-colour spool paints several colours across one pill, so the label has to answer to
    /// their combined brightness rather than to whichever happened to be listed first.
    func testMultiColourSwatchAveragesItsConstituents() {
        XCTAssertEqual(
            SwatchContrast.preferredForeground(colorHex: "FFFFFF", extraColorHexes: ["FEFEFE"]),
            .dark
        )
        XCTAssertEqual(
            SwatchContrast.preferredForeground(colorHex: "FFFFFF", extraColorHexes: ["000000", "000000", "000000"]),
            .light
        )
    }

    /// With extra colours set, they are the whole swatch and the base colour isn't painted at all
    /// (Bambuddy's rule, which `FilamentSwatchView` follows) — so it mustn't sway the label either.
    func testBaseColourIsIgnoredWhenExtraColoursAreSet() {
        XCTAssertEqual(
            SwatchContrast.preferredForeground(colorHex: "000000", extraColorHexes: ["FFFFFF", "F0F0F0"]),
            .dark
        )
    }

    /// An empty slot has no colour at all and is drawn as a faint outline on the widget
    /// background, so the only readable choice is the light tone.
    func testMissingColourFallsBackToLightText() {
        XCTAssertEqual(SwatchContrast.preferredForeground(colorHex: nil), .light)
    }

    func testMalformedHexFallsBackToLightTextRatherThanGuessing() {
        XCTAssertEqual(SwatchContrast.preferredForeground(colorHex: "not-a-colour"), .light)
    }

    /// Leading "#" is accepted: AppStore writes "#RRGGBB" into the snapshot.
    func testLeadingHashIsAccepted() {
        XCTAssertEqual(SwatchContrast.preferredForeground(colorHex: "#FFFFFF"), .dark)
    }
}
