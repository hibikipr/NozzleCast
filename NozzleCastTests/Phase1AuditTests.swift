import Foundation
import Testing
@testable import NozzleCast

/// Deterministic unit tests covering Phase 1 fixes.
struct Phase1AuditTests {
    // MARK: - BambuddyConfig.normalizedServerURL(from:)

    @Test(arguments: [
        "",
        "   ",
        "\n\t",
        "https://",
        "http://",
        "ftp://example.com",
        "javascript:alert(1)",
        "file:///etc/passwd",
        "://example.com",
    ])
    func normalizedServerURLRejectsInvalidInputs(_ raw: String) {
        #expect(BambuddyConfig.normalizedServerURL(from: raw) == nil)
    }

    @Test func normalizedServerURLPrependsHTTPSForBareHost() {
        let url = BambuddyConfig.normalizedServerURL(from: "bambuddy.local")
        #expect(url?.absoluteString == "https://bambuddy.local")
        #expect(url?.scheme == "https")
        #expect(url?.host == "bambuddy.local")
    }

    @Test(arguments: [
        "https://bambuddy.local/",
        "https://bambuddy.local///",
        "  https://bambuddy.local/  ",
    ])
    func normalizedServerURLStripsTrailingSlashesAndWhitespace(_ raw: String) {
        let url = BambuddyConfig.normalizedServerURL(from: raw)
        #expect(url?.absoluteString == "https://bambuddy.local")
    }

    @Test func normalizedServerURLPreservesSchemePortAndPath() {
        let url = BambuddyConfig.normalizedServerURL(from: "http://192.168.1.10:8000/sub/")
        #expect(url?.absoluteString == "http://192.168.1.10:8000/sub")
        #expect(url?.scheme == "http")
        #expect(url?.host == "192.168.1.10")
        #expect(url?.port == 8000)
        #expect(url?.path == "/sub")
    }

    @Test func normalizedServerURLNormalizesUppercaseScheme() {
        let url = BambuddyConfig.normalizedServerURL(from: "HTTPS://bambuddy.local/")
        #expect(url?.scheme == "https")
        #expect(url?.host == "bambuddy.local")
    }

    // MARK: - EditSpoolSheet.parseDecimal(_:)

    @Test(arguments: [
        ("19.99", 19.99),
        (" 24,50 ", 24.5),
        ("0", 0.0),
        ("100", 100.0),
        ("\n\t0,75\n", 0.75),
    ])
    func parseDecimalParsesValidNumbers(_ raw: String, _ expected: Double) throws {
        let parsed = try #require(EditSpoolSheet.parseDecimal(raw))
        #expect(abs(parsed - expected) < 0.000_001)
    }

    @Test(arguments: [
        "",
        "   ",
        "abc",
        "19,99abc",
        "19.99abc",
        "inf",
        "-inf",
        "nan",
        "NaN",
    ])
    func parseDecimalRejectsInvalidOrNonFiniteInputs(_ raw: String) {
        #expect(EditSpoolSheet.parseDecimal(raw) == nil)
    }
}
