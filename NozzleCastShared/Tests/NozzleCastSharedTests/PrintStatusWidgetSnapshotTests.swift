import Foundation
import Testing
@testable import NozzleCastShared

/// The Print Status widget reads the app's snapshots from the App Group. These cover the store's
/// round trip and tolerance of bad or older data, and the ranking that decides which printer the
/// widget shows. `now` is fixed in every test so nothing depends on the real clock.
@Suite(.serialized)
struct PrintStatusWidgetSnapshotTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let storageKey = "printStatusWidgetSnapshot"

    /// The store's `defaultsOverride` is static, so suites run serialized and every test resets it.
    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suiteName = "PrintStatusWidgetSnapshotTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        PrintStatusWidgetStore.defaultsOverride = defaults
        defer {
            PrintStatusWidgetStore.defaultsOverride = nil
            defaults.removePersistentDomain(forName: suiteName)
        }
        try body(defaults)
    }

    private func snapshot(
        _ id: String,
        name: String? = nil,
        active: Bool = false,
        estimatedEndAt: Date? = nil,
        finishedAt: Date? = nil
    ) -> PrintStatusSnapshot {
        PrintStatusSnapshot(
            printerID: id,
            printerName: name ?? id,
            isActive: active,
            estimatedEndAt: estimatedEndAt,
            finishedAt: finishedAt
        )
    }

    // MARK: - Store round trip

    @Test func saveThenLoadRoundTripsSnapshotsAndSetsLastSavedAt() {
        withIsolatedDefaults { _ in
            let saved = [
                snapshot("vich2c", name: "Vich 2C", active: true, estimatedEndAt: Self.now.addingTimeInterval(600)),
                snapshot("samp1s", name: "Samp 1S", finishedAt: Self.now.addingTimeInterval(-3600)),
            ]
            #expect(PrintStatusWidgetStore.lastSavedAt == nil)

            PrintStatusWidgetStore.save(saved)

            #expect(PrintStatusWidgetStore.load() == saved)
            #expect(PrintStatusWidgetStore.lastSavedAt != nil)
        }
    }

    @Test func loadReturnsEmptyWhenNothingIsSaved() {
        withIsolatedDefaults { _ in
            #expect(PrintStatusWidgetStore.load().isEmpty)
        }
    }

    @Test func loadReturnsEmptyForGarbageData() {
        withIsolatedDefaults { defaults in
            defaults.set(Data("x".utf8), forKey: Self.storageKey)
            #expect(PrintStatusWidgetStore.load().isEmpty)
        }
    }

    // MARK: - Decoding older and newer snapshots

    @Test func snapshotWithOnlyIdentityFieldsDecodesWithDefaults() throws {
        let json = Data(#"{"printerID":"vich2c","printerName":"Vich 2C"}"#.utf8)

        let decoded = try JSONDecoder().decode(PrintStatusSnapshot.self, from: json)

        #expect(decoded.printerID == "vich2c")
        #expect(decoded.printerName == "Vich 2C")
        #expect(decoded.isActive == false)
        #expect(decoded.progress == 0)
        #expect(decoded.stateLabel == "")
        #expect(decoded.jobName == nil)
        #expect(decoded.estimatedEndAt == nil)
        #expect(decoded.currentLayer == nil)
        #expect(decoded.totalLayers == nil)
        #expect(decoded.nozzleTempC == nil)
        #expect(decoded.rightNozzleTempC == nil)
        #expect(decoded.bedTempC == nil)
        #expect(decoded.issueSeverity == nil)
        #expect(decoded.issueCount == nil)
        #expect(decoded.stageDetail == nil)
        #expect(decoded.lastJobName == nil)
        #expect(decoded.finishedAt == nil)
    }

    @Test func snapshotWithAnUnknownKeyStillDecodes() throws {
        let json = Data(#"{"printerID":"vich2c","printerName":"Vich 2C","someFutureField":42,"isActive":true}"#.utf8)

        let decoded = try JSONDecoder().decode(PrintStatusSnapshot.self, from: json)

        #expect(decoded.printerID == "vich2c")
        #expect(decoded.isActive == true)
    }

    @Test func storeLoadsOlderSnapshotDataFromDefaults() {
        withIsolatedDefaults { defaults in
            let older = Data(#"[{"printerID":"vich2c","printerName":"Vich 2C","futureKey":"y"}]"#.utf8)
            defaults.set(older, forKey: Self.storageKey)

            let loaded = PrintStatusWidgetStore.load()

            #expect(loaded.count == 1)
            #expect(loaded.first?.printerID == "vich2c")
            #expect(loaded.first?.isActive == false)
        }
    }

    // MARK: - Ranking

    @Test func printEndingSoonerRanksBeforePrintEndingLater() {
        let soon = snapshot("soon", active: true, estimatedEndAt: Self.now.addingTimeInterval(10 * 60))
        let later = snapshot("later", active: true, estimatedEndAt: Self.now.addingTimeInterval(60 * 60))

        let ranked = PrintStatusSnapshot.ranked([later, soon], now: Self.now)

        #expect(ranked.map(\.printerID) == ["soon", "later"])
    }

    @Test func activePrintsWithAFutureEstimateRankBeforePausedPrints() {
        let ending = snapshot("ending", active: true, estimatedEndAt: Self.now.addingTimeInterval(60 * 60))
        let paused = snapshot("paused", active: true, estimatedEndAt: nil)

        let ranked = PrintStatusSnapshot.ranked([paused, ending], now: Self.now)

        #expect(ranked.map(\.printerID) == ["ending", "paused"])
    }

    @Test func pausedPrintsRankBeforeIdlePrinters() {
        let paused = snapshot("paused", active: true, estimatedEndAt: nil)
        let idle = snapshot("idle", finishedAt: Self.now.addingTimeInterval(-60))

        let ranked = PrintStatusSnapshot.ranked([idle, paused], now: Self.now)

        #expect(ranked.map(\.printerID) == ["paused", "idle"])
    }

    @Test func idlePrintersRankMostRecentlyFinishedFirstWithNeverFinishedLast() {
        let hourAgo = snapshot("hourAgo", name: "A", finishedAt: Self.now.addingTimeInterval(-3600))
        let dayAgo = snapshot("dayAgo", name: "B", finishedAt: Self.now.addingTimeInterval(-86_400))
        let neverFinished = snapshot("never", name: "C", finishedAt: nil)
        let tenMinutesAgo = snapshot("tenMin", name: "D", finishedAt: Self.now.addingTimeInterval(-600))

        let ranked = PrintStatusSnapshot.ranked(
            [dayAgo, neverFinished, hourAgo, tenMinutesAgo],
            now: Self.now
        )

        #expect(ranked.map(\.printerID) == ["tenMin", "hourAgo", "dayAgo", "never"])
    }

    /// An estimate that has already passed means the print is overdue, not about to finish, so it
    /// sits with the paused tier rather than ahead of it.
    @Test func activePrintWithAPastEstimateRanksWithThePausedTier() {
        let future = snapshot("future", name: "Zed", active: true, estimatedEndAt: Self.now.addingTimeInterval(600))
        let overdue = snapshot("overdue", name: "Mid", active: true, estimatedEndAt: Self.now.addingTimeInterval(-600))
        let idle = snapshot("idle", name: "Aaa", finishedAt: Self.now.addingTimeInterval(-60))

        let ranked = PrintStatusSnapshot.ranked([idle, overdue, future], now: Self.now)

        // The overdue print sorts by name within the paused tier, after the future-estimate print
        // (tier 0) and before the idle printer (tier 2). Had it been ranked as tier 0 it would have
        // a finite end time in the past and sorted first.
        #expect(ranked.map(\.printerID) == ["future", "overdue", "idle"])
    }

    // MARK: - Pick

    @Test func pickReturnsTheRequestedPrinterEvenWhenNotFirstInRanking() {
        let first = snapshot("first", active: true, estimatedEndAt: Self.now.addingTimeInterval(60))
        let second = snapshot("second", active: true, estimatedEndAt: Self.now.addingTimeInterval(3600))

        let picked = PrintStatusSnapshot.pick([first, second], printerID: "second", now: Self.now)

        #expect(picked?.printerID == "second")
    }

    @Test func pickFallsBackToTheFirstRankedPrinterForAnUnknownID() {
        let first = snapshot("first", active: true, estimatedEndAt: Self.now.addingTimeInterval(60))
        let second = snapshot("second", active: true, estimatedEndAt: Self.now.addingTimeInterval(3600))

        let picked = PrintStatusSnapshot.pick([second, first], printerID: "removed", now: Self.now)

        #expect(picked?.printerID == "first")
    }

    @Test func pickFallsBackToTheFirstRankedPrinterForANilID() {
        let first = snapshot("first", active: true, estimatedEndAt: Self.now.addingTimeInterval(60))
        let second = snapshot("second", active: true, estimatedEndAt: Self.now.addingTimeInterval(3600))

        let picked = PrintStatusSnapshot.pick([second, first], printerID: nil, now: Self.now)

        #expect(picked?.printerID == "first")
    }

    @Test func pickReturnsNilForAnEmptyList() {
        #expect(PrintStatusSnapshot.pick([], printerID: "anything", now: Self.now) == nil)
        #expect(PrintStatusSnapshot.pick([], printerID: nil, now: Self.now) == nil)
    }
}
