import XCTest
@testable import NozzleCastShared

/// `materialLabel` is Bambu's raw `tray_type` / the spool's own material string, straight from
/// the printer with no normalisation (see AppStore.makeAMSSnapshots) — so it is unbounded in
/// length. In the AMS widget it renders inside a swatch roughly 28pt wide on medium and 65pt on
/// large, where "Support for PLA" either shrank to ~4pt or truncated to "Support...".
final class MaterialLabelTests: XCTestCase {

    func testOrdinaryMaterialIsLeftAlone() {
        XCTAssertEqual(MaterialLabel.short("PLA"), "PLA")
    }

    func testCompoundMaterialIsLeftAlone() {
        XCTAssertEqual(MaterialLabel.short("PETG-CF"), "PETG-CF")
    }

    func testSupportPrefixMovesToASuffix() {
        XCTAssertEqual(MaterialLabel.short("Support for PLA"), "PLA SUP")
    }

    /// The material a support filament pairs with can itself be a list; keeping it beats
    /// discarding it, and the caller's truncation handles the rare overflow.
    func testSupportPrefixKeepsACompoundBaseMaterial() {
        XCTAssertEqual(MaterialLabel.short("Support for PLA/PETG"), "PLA/PETG SUP")
    }

    func testSupportPrefixMatchIsCaseInsensitive() {
        XCTAssertEqual(MaterialLabel.short("SUPPORT FOR ABS"), "ABS SUP")
    }

    /// Bambu also ships bare "Support" variants with no paired material named.
    func testBareSupportBecomesJustTheSuffix() {
        XCTAssertEqual(MaterialLabel.short("Support"), "SUP")
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(MaterialLabel.short("  PLA  "), "PLA")
    }

    func testInternalWhitespaceIsCollapsed() {
        XCTAssertEqual(MaterialLabel.short("Support  for   PLA"), "PLA SUP")
    }

    func testNilStaysNil() {
        XCTAssertNil(MaterialLabel.short(nil))
    }

    /// An empty or whitespace-only label must come back nil, not "" — the widget draws no label
    /// at all rather than an empty contrast-coloured box.
    func testWhitespaceOnlyBecomesNil() {
        XCTAssertNil(MaterialLabel.short("   "))
    }
}
