import Foundation
import Testing
import NozzleCastShared
@testable import NozzleCast

/// Deterministic unit tests covering Phase 3 hardening and previously untested modules.
struct Phase3AuditTests {
    private static func makeSpool(
        material: String = "PLA",
        subtype: String? = nil,
        remainingPercent: Int = 100,
        netWeightGrams: Int = 1000,
        location: SpoolLocation = .storage(name: nil),
        archivedAt: Date? = nil,
        archivedDateIsKnown: Bool = true
    ) -> Spool {
        Spool(
            id: "test-spool",
            material: material,
            colorName: "Black",
            colorHex: "#000000",
            brand: "TestBrand",
            remainingPercent: remainingPercent,
            netWeightGrams: netWeightGrams,
            location: location,
            subtype: subtype,
            archivedAt: archivedAt,
            archivedDateIsKnown: archivedDateIsKnown
        )
    }

    private static func makePrinter(
        name: String = "Studio H2C",
        etaMinutesRemaining: Int? = nil,
        amsUnits: [AMSUnit] = []
    ) -> Printer {
        Printer(
            id: "printer-1",
            name: name,
            model: "H2C",
            state: .printing,
            etaMinutesRemaining: etaMinutesRemaining,
            nozzle: TemperatureReading(current: 220, target: 220),
            bed: TemperatureReading(current: 60, target: 60),
            lightOn: true,
            amsUnits: amsUnits
        )
    }

    private static func makePlistData(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    // MARK: - 1. Regex & Word-Boundary Material Handling

    @Test func materialFamilyWordBoundaryHelpers() {
        #expect(MaterialFamily.of("PLA Matte") == "PLA")
        #expect(MaterialFamily.of("PLA-CF") == "PLA")
        #expect(MaterialFamily.of("Support for PLA") == "SUPPORT")
        #expect(MaterialFamily.of("") == nil)

        #expect(MaterialFamily.same("PLA", "PLA Matte"))
        #expect(MaterialFamily.same("PLA-CF", "PLA Basic"))
        #expect(!MaterialFamily.same("PLA", "Support for PLA"))
        #expect(!MaterialFamily.same("", "PLA"))

        #expect(MaterialFamily.containsMaterialToken("PA", in: "PA-CF"))
        #expect(MaterialFamily.containsMaterialToken("PA", in: "PA Impact"))
        #expect(!MaterialFamily.containsMaterialToken("PA", in: "Impact"))
        #expect(!MaterialFamily.containsMaterialToken("PA", in: "Sparkle"))
        #expect(MaterialFamily.containsMaterialToken("PLA+", in: "Silk PLA+ Red"))
        #expect(!MaterialFamily.containsMaterialToken("   ", in: "PLA"))
    }

    @Test func ofdClientSubtypeRespectsWordBoundariesAndPlusSuffix() {
        #expect(OFDClient.subtype(from: "Silk PLA+ Red", material: "PLA+") == "Silk Red")
        #expect(OFDClient.subtype(from: "PLA+ Silk", material: "PLA") == "Silk")
        #expect(OFDClient.subtype(from: "Space Gray PA", material: "PA") == "Space Gray")
        #expect(OFDClient.subtype(from: "PLA+", material: "PLA+") == nil)
        #expect(OFDClient.subtype(from: " - + ", material: "PLA") == nil)
        #expect(OFDClient.subtype(from: "Matte", material: "") == "Matte")
    }

    @Test func spoolmanDBColorNameRespectsWordBoundariesAndPlusSuffix() {
        #expect(SpoolmanDBCommunityClient.colorName(from: "PA Sparkle Black", material: "PA") == "Sparkle Black")
        #expect(SpoolmanDBCommunityClient.colorName(from: "Silk PLA+ Gold", material: "PLA+") == "Silk Gold")
        #expect(SpoolmanDBCommunityClient.colorName(from: "PLA+ Blue", material: "PLA") == "Blue")
        #expect(SpoolmanDBCommunityClient.colorName(from: "PLA", material: "PLA") == nil)
    }

    @Test func spoolMaterialWithSubtypeAvoidsSubstringFalsePositivesAndDoubling() {
        #expect(Self.makeSpool(material: "PA", subtype: "Impact").materialWithSubtype == "PA Impact")
        #expect(Self.makeSpool(material: "PA", subtype: "Sparkle").materialWithSubtype == "PA Sparkle")
        #expect(Self.makeSpool(material: "PLA", subtype: "PLA Matte").materialWithSubtype == "PLA Matte")
        #expect(Self.makeSpool(material: "PLA+", subtype: "PLA+ Silk").materialWithSubtype == "PLA+ Silk")
        #expect(Self.makeSpool(material: "PA", subtype: "   ").materialWithSubtype == "PA")
    }

    @Test func shoppingListItemTitleHandlesBlankSubtypeAndWordBoundaries() {
        let blankSubtype = ShoppingListItem(
            id: "1",
            bambuddyID: 1,
            material: "PLA",
            subtype: "   \n ",
            brand: "Bambu Lab",
            colorName: "Black",
            quantity: 1,
            note: nil,
            status: .pending,
            addedAt: nil
        )
        #expect(blankSubtype.title == "Bambu Lab PLA · Black")

        let paImpact = ShoppingListItem(
            id: "2",
            bambuddyID: 2,
            material: "PA",
            subtype: "Impact",
            brand: "Polymaker",
            colorName: "Black",
            quantity: 1,
            note: nil,
            status: .pending,
            addedAt: nil
        )
        #expect(paImpact.title == "Polymaker PA Impact · Black")

        let alreadyNamedMaterial = ShoppingListItem(
            id: "3",
            bambuddyID: 3,
            material: "PLA",
            subtype: "PLA Basic",
            brand: "Bambu Lab",
            colorName: "Jade White",
            quantity: 1,
            note: nil,
            status: .pending,
            addedAt: nil
        )
        #expect(alreadyNamedMaterial.title == "Bambu Lab PLA Basic · Jade White")

        let minimal = ShoppingListItem(
            id: "4",
            bambuddyID: 4,
            material: "PA",
            subtype: "Sparkle",
            brand: "  ",
            colorName: " ",
            quantity: 1,
            note: nil,
            status: .purchased,
            addedAt: nil
        )
        #expect(minimal.title == "PA Sparkle")
    }

    // MARK: - 2. FilamentCode.classify & FilamentCode.extractBarcode

    @Test(arguments: [
        "AB12345670",
        "LOT20260401",
        "lot20260401",
        "CA04045",
        "00123458",
        "123456789013",
        "",
    ])
    func classifyTreatsAlphanumericAndInvalidChecksumCodesAsSKU(_ raw: String) {
        let classified = FilamentCode.classify(raw)
        #expect(classified.kind == .sku)
        #expect(classified.code == raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
    }

    @Test(arguments: [
        ("00123457", "123457"),
        ("0012-3457", "123457"),
        ("6938936714712", "6938936714712"),
        ("012345678905", "12345678905"),
        ("0012345678905", "12345678905"),
    ])
    func classifyAcceptsChecksumValidGTINsIncludingLeadingZeroEAN8(_ raw: String, _ expectedCanon: String) {
        let classified = FilamentCode.classify(raw)
        #expect(classified.kind == .gtin)
        #expect(classified.code == expectedCanon)
    }

    @Test func extractBarcodeFindsEAN8AndPrefersValidGTINOverInvalidBatchNumber() {
        #expect(FilamentCode.extractBarcode(from: "EAN: 00123457\nWeight: 1kg") == "00123457")
        #expect(FilamentCode.extractBarcode(from: "Code 00123457") == "00123457")

        let batchBeforeValidEAN8 = """
        Lot 123456789013
        Barcode 00123457
        """
        #expect(FilamentCode.extractBarcode(from: batchBeforeValidEAN8) == "00123457")

        let invalidLabelledBeforeValidBare = """
        EAN: 123456789013
        00123457
        """
        #expect(FilamentCode.extractBarcode(from: invalidLabelledBeforeValidBare) == "00123457")

        let batchOnly = "Batch 123456789013"
        #expect(FilamentCode.extractBarcode(from: batchOnly) == "123456789013")

        #expect(FilamentCode.extractBarcode(from: "Short 1234567") == nil)
    }

    // MARK: - 3. FilamentTitleParser

    @Test func parserDoesNotMatchSubstringsInsideBrandOrMaterialWords() {
        let matterHackers = FilamentTitleParser.parse(title: "MatterHackers PRO PLA Black")
        #expect(matterHackers.brand == "MatterHackers")
        #expect(matterHackers.material == "PLA")
        #expect(matterHackers.subtype == nil)
        #expect(matterHackers.colorName == "Black")
        #expect(matterHackers.rgba == "000000FF")

        let polycarbonate = FilamentTitleParser.parse(title: "Polycarbonate Natural")
        #expect(polycarbonate.subtype == nil)
        #expect(polycarbonate.material == nil)
        #expect(polycarbonate.colorName == "Natural")
        #expect(polycarbonate.rgba == "EDE6D6FF")
    }

    @Test func parserPrefersChromaticColorWithClarityModifierOverPlainClarityGray() {
        let transparentBlue = FilamentTitleParser.parse(title: "Transparent Blue PLA")
        #expect(transparentBlue.material == "PLA")
        #expect(transparentBlue.colorName == "Transparent Blue")
        #expect(transparentBlue.rgba == "0050FFFF")

        let clearRed = FilamentTitleParser.parse(title: "Clear Red PETG")
        #expect(clearRed.material == "PETG")
        #expect(clearRed.colorName == "Clear Red")
        #expect(clearRed.rgba == "FF0000FF")

        let plainClear = FilamentTitleParser.parse(title: "Clear PETG")
        #expect(plainClear.colorName == "Clear")
        #expect(plainClear.rgba == "EEEEEEFF")

        let nonModifierWord = FilamentTitleParser.parse(title: "Unclear Red PLA")
        #expect(nonModifierWord.colorName == "Red")
        #expect(nonModifierWord.rgba == "FF0000FF")
    }

    @Test func parserExtraBrandsUseWordBoundaries() {
        let mainland = FilamentTitleParser.parse(title: "MAINLAND PLA White", extraBrands: ["Inland"])
        #expect(mainland.brand == nil)
        #expect(mainland.material == "PLA")
        #expect(mainland.colorName == "White")

        let customMatch = FilamentTitleParser.parse(title: "FormFutura PETG Red", extraBrands: ["FormFutura"])
        #expect(customMatch.brand == "FormFutura")

        let customSubstring = FilamentTitleParser.parse(title: "DeformFutura PETG Red", extraBrands: ["FormFutura"])
        #expect(customSubstring.brand == nil)
    }

    @Test func parserExtractsTempsWeightAndHexOverride() {
        let parsed = FilamentTitleParser.parse(title: "Bambu Lab PLA+ 1.75mm Black 200-220°C 1kg #112233")
        #expect(parsed.brand == "Bambu Lab")
        #expect(parsed.material == "PLA")
        #expect(parsed.subtype == "Plus")
        #expect(parsed.colorName == "Black")
        #expect(parsed.rgba == "112233FF")
        #expect(parsed.nozzleTempMin == 200)
        #expect(parsed.nozzleTempMax == 220)
        #expect(parsed.labelWeightGrams == 1000)

        let empty = FilamentTitleParser.parse(title: "   \n ")
        #expect(empty.brand == nil)
        #expect(empty.material == nil)
        #expect(empty.colorName == nil)
    }

    // MARK: - 4. HMSCodeLookup.extractTitle & stripWikiTitleChrome

    @Test func hmsExtractTitleHandlesMalformedTagOrderWithoutCrashing() {
        #expect(HMSCodeLookup.extractTitle(from: "<head></title><title>Unclosed") == nil)
        #expect(HMSCodeLookup.extractTitle(from: "</title><head></head>") == nil)
        #expect(HMSCodeLookup.extractTitle(from: "</title><title>Recovered</title>") == "Recovered")
    }

    @Test func hmsExtractTitleDecodesCaseInsensitiveTitleWithAttributesAndEntities() {
        let html = #"<TITLE lang="en">HMS_0500_0500_0001_0007 &amp; MQTT &#39;Test&#39; | Bambu Lab Wiki</TITLE>"#
        let extracted = HMSCodeLookup.extractTitle(from: html)
        #expect(extracted == "HMS_0500_0500_0001_0007 & MQTT 'Test' | Bambu Lab Wiki")

        let allEntitiesHTML = "<title>&lt;Tag&gt; &quot;Quote&quot; &apos;A&apos; &#x27;B&#x27; &amp; C&nbsp;D</title>"
        #expect(HMSCodeLookup.extractTitle(from: allEntitiesHTML) == "<Tag> \"Quote\" 'A' 'B' & C D")

        let colonHTML = #"<TITLE lang="en">HMS_0500_0500_0001_0007: MQTT &amp; &#39;Test&#39; | Bambu Lab Wiki</TITLE>"#
        let colonTitle = HMSCodeLookup.extractTitle(from: colonHTML)
        #expect(colonTitle.flatMap { HMSCodeLookup.stripWikiTitleChrome($0, code: "0500-0500-0001-0007") } == "MQTT & 'Test'")
    }

    @Test(arguments: [
        "Page Not Found | Bambu Lab Wiki",
        "404 - Page Not Found | Bambu Lab Wiki",
        "404 Not Found",
        "Bambu Lab Wiki",
        "HMS_0500_0500_0001_0007 | Bambu Lab Wiki",
        "HMS_0500-0500-0001-0007 | Bambu Lab Wiki",
        "HMS_0500_0500_0001_0007 & MQTT 'Test' | Bambu Lab Wiki",
        "   | Bambu Lab Wiki",
    ])
    func hmsStripWikiTitleChromeRejectsGenericAndNotFoundTitles(_ title: String) {
        #expect(HMSCodeLookup.stripWikiTitleChrome(title, code: "0500-0500-0001-0007") == nil)
    }

    // MARK: - 5. Config & Storage Hardening

    @Test(arguments: [
        "ftp://relay.local",
        "javascript:alert(1)",
        "https://",
        "http://",
        "   ",
        "",
        "://relay.local",
        "file:///tmp/relay",
        "relay.example.com",
    ])
    func relayConfigValidatedURLRejectsUnsafeOrIncompleteInputs(_ raw: String) {
        #expect(RelayConfigStore.validatedURL(from: raw) == nil)
    }

    @Test func relayConfigValidatedURLAcceptsHTTPAndHTTPSAndNormalizesScheme() {
        let https = RelayConfigStore.validatedURL(from: "https://relay.example.com")
        #expect(https?.absoluteString == "https://relay.example.com")

        let normalized = RelayConfigStore.validatedURL(from: "  HTTPS://relay.example.com:8443/push  ")
        #expect(normalized?.scheme == "https")
        #expect(normalized?.host == "relay.example.com")
        #expect(normalized?.port == 8443)
        #expect(normalized?.path == "/push")

        let http = RelayConfigStore.validatedURL(from: "http://192.168.1.50:3000")
        #expect(http?.absoluteString == "http://192.168.1.50:3000")
    }

    @Test func firebaseConfigValidateAcceptsValidPlistAndTrimsProjectID() throws {
        let data = try Self.makePlistData([
            "API_KEY": "AIzaSyTestKey123",
            "GCM_SENDER_ID": "1234567890",
            "PROJECT_ID": "  nozzlecast-test  ",
            "GOOGLE_APP_ID": "1:1234567890:ios:abcdef0123456789",
        ])
        let projectID = try FirebaseConfigStore.validate(data)
        #expect(projectID == "nozzlecast-test")
    }

    @Test(arguments: ["API_KEY", "GCM_SENDER_ID", "PROJECT_ID", "GOOGLE_APP_ID"])
    func firebaseConfigValidateRejectsEmptyOrNonStringRequiredKeys(_ key: String) throws {
        let base: [String: Any] = [
            "API_KEY": "AIzaSyTestKey123",
            "GCM_SENDER_ID": "1234567890",
            "PROJECT_ID": "nozzlecast-test",
            "GOOGLE_APP_ID": "1:1234567890:ios:abcdef0123456789",
        ]

        let badValues: [Any] = ["", "   \n", 12345, true, ["nested"]]
        for badValue in badValues {
            var dict = base
            dict[key] = badValue
            let data = try Self.makePlistData(dict)
            var capturedMissing: [String]?
            do {
                _ = try FirebaseConfigStore.validate(data)
                Issue.record("Expected validation failure for \(key) with value \(badValue)")
            } catch let error as FirebaseConfigStore.ImportError {
                if case .missingKeys(let keys) = error {
                    capturedMissing = keys
                } else {
                    Issue.record("Expected .missingKeys for \(key), got \(error)")
                }
            }
            #expect(capturedMissing == [key])
        }

        var omitted = base
        omitted.removeValue(forKey: key)
        let omittedData = try Self.makePlistData(omitted)
        #expect(throws: FirebaseConfigStore.ImportError.self) {
            try FirebaseConfigStore.validate(omittedData)
        }
    }

    @Test func firebaseConfigValidateRejectsInvalidAppIDAndUnreadableData() throws {
        let badAppIDData = try Self.makePlistData([
            "API_KEY": "AIzaSyTestKey123",
            "GCM_SENDER_ID": "1234567890",
            "PROJECT_ID": "nozzlecast-test",
            "GOOGLE_APP_ID": "1:1234567890:android:abcdef",
        ])
        do {
            _ = try FirebaseConfigStore.validate(badAppIDData)
            Issue.record("Expected .invalidAppID")
        } catch let error as FirebaseConfigStore.ImportError {
            guard case .invalidAppID = error else {
                Issue.record("Expected .invalidAppID, got \(error)")
                return
            }
        }

        do {
            _ = try FirebaseConfigStore.validate(Data("not a plist".utf8))
            Issue.record("Expected .unreadable")
        } catch let error as FirebaseConfigStore.ImportError {
            guard case .unreadable = error else {
                Issue.record("Expected .unreadable, got \(error)")
                return
            }
        }

        let arrayData = try PropertyListSerialization.data(fromPropertyList: ["not", "a", "dict"], format: .xml, options: 0)
        do {
            _ = try FirebaseConfigStore.validate(arrayData)
            Issue.record("Expected .unreadable for array plist")
        } catch let error as FirebaseConfigStore.ImportError {
            guard case .unreadable = error else {
                Issue.record("Expected .unreadable, got \(error)")
                return
            }
        }
    }

    @Test func pushSharedStoreSanitizedImageFilenameNeutralizesUnsafeIDs() {
        #expect(PushSharedStore.sanitizedImageFilename(for: "abc-123_XYZ") == "abc-123_XYZ.jpg")

        let maxSafe = String(repeating: "a", count: 128)
        #expect(PushSharedStore.sanitizedImageFilename(for: maxSafe) == "\(maxSafe).jpg")

        let unsafeIDs = [
            "../relay-connection",
            "foo/bar",
            "",
            "..",
            "a\\b",
            "id with spaces",
            "alert.jpg",
            String(repeating: "a", count: 129),
        ]
        for id in unsafeIDs {
            let filename = PushSharedStore.sanitizedImageFilename(for: id)
            #expect(!filename.contains("/"))
            #expect(!filename.contains(".."))
            #expect(!filename.contains("\\"))
            #expect(filename.hasSuffix(".jpg"))
            #expect(filename.count == 68) // 64 hex chars + ".jpg"
            #expect(filename == PushSharedStore.sanitizedImageFilename(for: id))
        }

        #expect(
            PushSharedStore.sanitizedImageFilename(for: "../a")
                != PushSharedStore.sanitizedImageFilename(for: "../b")
        )
    }

    // MARK: - 6. Model Clamps & Helpers

    @Test func printerETADescriptionClampsNegativeMinutes() {
        #expect(Self.makePrinter(etaMinutesRemaining: nil).etaDescription == nil)
        #expect(Self.makePrinter(etaMinutesRemaining: -45).etaDescription == "0m")
        #expect(Self.makePrinter(etaMinutesRemaining: 0).etaDescription == "0m")
        #expect(Self.makePrinter(etaMinutesRemaining: 15).etaDescription == "15m")
        #expect(Self.makePrinter(etaMinutesRemaining: 60).etaDescription == "1h 0m")
        #expect(Self.makePrinter(etaMinutesRemaining: 72).etaDescription == "1h 12m")
    }

    @Test func spoolRemainingGramsClampsPercentAndNegativeWeight() {
        #expect(Self.makeSpool(remainingPercent: -25, netWeightGrams: 1000).remainingGrams == 0)
        #expect(Self.makeSpool(remainingPercent: 0, netWeightGrams: 1000).remainingGrams == 0)
        #expect(Self.makeSpool(remainingPercent: 33, netWeightGrams: 1000).remainingGrams == 330)
        #expect(Self.makeSpool(remainingPercent: 100, netWeightGrams: 750).remainingGrams == 750)
        #expect(Self.makeSpool(remainingPercent: 150, netWeightGrams: 1000).remainingGrams == 1000)
        #expect(Self.makeSpool(remainingPercent: 50, netWeightGrams: -500).remainingGrams == 0)
    }

    @Test func spoolLocationCaptionOmitsEmptyStorageNameAndFormatsAMS() {
        #expect(Self.makeSpool(location: .storage(name: nil)).locationCaption(printerName: { _ in nil }) == "In storage")
        #expect(Self.makeSpool(location: .storage(name: "")).locationCaption(printerName: { _ in nil }) == "In storage")
        #expect(Self.makeSpool(location: .storage(name: "  \n\t ")).locationCaption(printerName: { _ in nil }) == "In storage")
        #expect(Self.makeSpool(location: .storage(name: "  Dry Box A  ")).locationCaption(printerName: { _ in nil }) == "In storage · Dry Box A")

        let amsSpool = Self.makeSpool(location: .ams(printerID: "p1", amsIndex: 129, trayIndex: 0))
        let caption = amsSpool.locationCaption(
            printerName: { _ in "Studio H2C" },
            amsUnitName: { _, index in index == 129 ? "AMS-HT 2" : nil }
        )
        #expect(caption == "Studio H2C · AMS-HT 2 · Slot 1")

        let fallbackCaption = amsSpool.locationCaption(printerName: { _ in "Studio H2C" })
        #expect(fallbackCaption == "Studio H2C · AMS-HT · Slot 1")

        let archivedUnknown = Self.makeSpool(archivedAt: Date(timeIntervalSince1970: 1_000), archivedDateIsKnown: false)
        #expect(archivedUnknown.locationCaption(printerName: { _ in nil }) == "Archived")
    }

    @Test func amsUnitDisplayNameNumbersMultipleHTUnits() {
        let regular = AMSUnit(index: 0, trays: [], isHT: false)
        let ht1 = AMSUnit(index: 128, trays: [], isHT: true)
        let ht2 = AMSUnit(index: 129, trays: [], isHT: true)

        #expect(regular.displayName(position: 0) == "AMS 1")
        #expect(regular.displayName(position: 1) == "AMS 2")
        #expect(ht1.displayName(position: 0, htCount: 1) == "AMS-HT")
        #expect(ht1.displayName(position: 0, htCount: 2) == "AMS-HT 1")
        #expect(ht2.displayName(position: 1, htCount: 2) == "AMS-HT 2")

        let multiHTPrinter = Self.makePrinter(amsUnits: [regular, ht1, ht2])
        #expect(multiHTPrinter.amsUnitName(amsIndex: 0) == "AMS 1")
        #expect(multiHTPrinter.amsUnitName(amsIndex: 128) == "AMS-HT 1")
        #expect(multiHTPrinter.amsUnitName(amsIndex: 129) == "AMS-HT 2")
        #expect(multiHTPrinter.amsUnitName(amsIndex: 999) == nil)

        let singleHTPrinter = Self.makePrinter(amsUnits: [regular, ht1])
        #expect(singleHTPrinter.amsUnitName(amsIndex: 128) == "AMS-HT")
    }

    @Test func printLiveActivityFittingBudgetDropsCoverImageAndTruncatesToFit() throws {
        let encoder = JSONEncoder()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let smallState = PrintActivityAttributes.ContentState(
            progress: 0.5,
            stateLabel: "Printing",
            jobName: "Bench.3mf",
            startedAt: now,
            estimatedEndAt: now.addingTimeInterval(600),
            coverImage: Data(repeating: 0xAA, count: 64),
            stageDetail: "Printing"
        )
        let fittedSmall = PrintLiveActivityManager.fittingBudget(smallState)
        #expect(fittedSmall.coverImage == smallState.coverImage)
        #expect(fittedSmall.jobName == "Bench.3mf")
        #expect(try encoder.encode(fittedSmall).count <= 3800)

        let oversizedCoverState = PrintActivityAttributes.ContentState(
            progress: 0.5,
            stateLabel: "Printing",
            jobName: "Organizer.3mf",
            startedAt: now,
            estimatedEndAt: now.addingTimeInterval(600),
            coverImage: Data(repeating: 0xAB, count: 3500),
            stageDetail: "Heating chamber"
        )
        let fittedCover = PrintLiveActivityManager.fittingBudget(oversizedCoverState)
        #expect(fittedCover.coverImage == nil)
        #expect(fittedCover.jobName == "Organizer.3mf")
        #expect(fittedCover.stageDetail == "Heating chamber")
        #expect(try encoder.encode(fittedCover).count <= 3800)

        let hugeTextState = PrintActivityAttributes.ContentState(
            progress: 0.5,
            stateLabel: "Printing",
            jobName: String(repeating: "J", count: 5000),
            startedAt: now,
            estimatedEndAt: now.addingTimeInterval(600),
            coverImage: Data(repeating: 0xAC, count: 3500),
            liveSnapshot: Data(repeating: 0xAD, count: 128),
            stageDetail: String(repeating: "S", count: 4200)
        )
        let fittedHuge = PrintLiveActivityManager.fittingBudget(hugeTextState)
        #expect(fittedHuge.coverImage == nil)
        #expect(fittedHuge.liveSnapshot == nil)
        #expect(try encoder.encode(fittedHuge).count <= 3800)
        if let jobName = fittedHuge.jobName {
            #expect(jobName.hasSuffix("…"))
        }
        if let stageDetail = fittedHuge.stageDetail {
            #expect(stageDetail.count < 4200)
        }
    }
}
