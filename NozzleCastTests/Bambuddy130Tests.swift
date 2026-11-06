import Foundation
import Testing
@testable import NozzleCast

/// Bambuddy 1.3.0's held queue jobs and per-print verdicts. The 409 bodies follow
/// `start_queue_item` in its `backend/app/api/routes/print_queue.py` (v1.3.0).
struct QueueStartFilamentHoldTests {
    @Test func readsUnmatchedFilament() throws {
        let body = #"{"detail":{"code":"unmatched_filament","missing":["PLA #A4AAAC","PETG Black"]}}"#
        let hold = try #require(QueueStartFilamentHold(body: body))
        #expect(hold == QueueStartFilamentHold(kind: .notLoaded, problems: ["PLA #A4AAAC", "PETG Black"]))
    }

    @Test func readsInsufficientFilament() throws {
        let body = #"{"detail":{"code":"insufficient_filament","deficit":[{"slot_id":2,"ams_id":0,"tray_id":1,"filament_type":"PETG","required_grams":120.4,"remaining_grams":39.6}]}}"#
        let hold = try #require(QueueStartFilamentHold(body: body))
        #expect(hold.kind == .tooShort)
        #expect(hold.problems.count == 1)
        #expect(hold.problems[0].contains("PETG"))
        #expect(hold.problems[0].contains("120"))
        #expect(hold.problems[0].contains("40"))
    }

    @Test func ignoresOtherConflicts() {
        #expect(QueueStartFilamentHold(body: #"{"detail":"Can only start pending items"}"#) == nil)
        #expect(QueueStartFilamentHold(body: #"{"detail":{"code":"budget_exceeded"}}"#) == nil)
        #expect(QueueStartFilamentHold(body: "not json") == nil)
    }
}

struct PerPrintVerdictTests {
    private func record(_ log: Int, archive: Int?, _ outcome: PrintRecord.Outcome = .completed) -> PrintRecord {
        PrintRecord(id: "log-\(log)", logID: log, archiveID: archive, name: "Clip", printerID: nil, printerName: nil, outcome: outcome, startedAt: nil, finishedAt: Date(), duration: nil, filamentGrams: nil, filamentType: nil, filamentColorHex: nil, cost: nil, failureReason: nil, verdict: nil, acceptsVerdict: false)
    }

    /// Newest first: two prints of archive 7, one of archive 8, a failed one, one without an archive.
    private var history: [PrintRecord] {
        [record(5, archive: 7), record(4, archive: 7), record(3, archive: 8, .failed), record(2, archive: 8), record(1, archive: nil)]
    }

    @Test func beforeBambuddy130OnlyTheLatestPrintOfAnArchive() {
        let marked = AppStore.markingVerdictEligibility(history)
        #expect(marked.map(\.acceptsVerdict) == [true, false, false, false, false])
    }

    @Test func fromBambuddy130EveryCompletedPrint() {
        let marked = AppStore.markingVerdictEligibility(history, eachPrint: true)
        #expect(marked.map(\.acceptsVerdict) == [true, true, false, true, false])
    }

    @Test func pageSaysWhetherBambuddyRatesEachPrint() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let new = try decoder.decode(BambuddyPrintLogPageDTO.self, from: Data(#"{"items":[],"total":0,"deleted_archive_ids":[]}"#.utf8))
        let old = try decoder.decode(BambuddyPrintLogPageDTO.self, from: Data(#"{"items":[],"total":0}"#.utf8))
        #expect(new.ratesEachPrint)
        #expect(!old.ratesEachPrint)
    }
}
