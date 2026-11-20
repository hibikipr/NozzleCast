import Foundation
import Testing
import NozzleCastShared
@testable import NozzleCast

/// The Print Status widget keeps a printer's last print when a save happens before the print
/// history is loaded, instead of dropping to a bare "Idle".
@MainActor
struct PrintStatusWidgetSnapshotTests {
    private func idlePrinter(job: String?) -> Printer {
        var printer = MockData.makePrinters()[0]
        printer.state = .idle
        printer.jobPhase = nil
        printer.jobFileName = job
        return printer
    }

    private func earlier(for printer: Printer, job: String?, active: Bool = false) -> PrintStatusSnapshot {
        PrintStatusSnapshot(
            printerID: PrintActivityAttributes.normalizedID(printer.name),
            printerName: printer.name,
            isActive: active,
            lastJobName: job,
            finishedAt: Date(timeIntervalSince1970: 1_000),
            lastOutcome: .completed
        )
    }

    @Test func noHistoryKeepsTheLastSavedPrint() {
        let printer = idlePrinter(job: "iPad Stand.3mf")
        let snapshot = AppStore.makePrintStatusSnapshots(printers: [printer], history: [], previous: [earlier(for: printer, job: "iPad Stand")])[0]
        #expect(snapshot.lastJobName == "iPad Stand")
        #expect(snapshot.lastOutcome == .completed)
        #expect(snapshot.finishedAt == Date(timeIntervalSince1970: 1_000))
    }

    @Test func noHistoryAndNoJobStillKeepsTheLastSavedPrint() {
        let printer = idlePrinter(job: nil)
        let snapshot = AppStore.makePrintStatusSnapshots(printers: [printer], history: [], previous: [earlier(for: printer, job: "iPad Stand")])[0]
        #expect(snapshot.lastJobName == "iPad Stand")
    }

    @Test func aDifferentJobOnThePrinterIsNotReplacedByTheOldOne() {
        let printer = idlePrinter(job: "Bloom Ring.3mf")
        let snapshot = AppStore.makePrintStatusSnapshots(printers: [printer], history: [], previous: [earlier(for: printer, job: "iPad Stand")])[0]
        #expect(snapshot.lastJobName == "Bloom Ring.3mf")
        #expect(snapshot.lastOutcome == nil)
    }

    @Test func aPrintThatWasRunningAtTheLastSaveIsNotCarried() {
        let printer = idlePrinter(job: "iPad Stand.3mf")
        let snapshot = AppStore.makePrintStatusSnapshots(printers: [printer], history: [], previous: [earlier(for: printer, job: "iPad Stand", active: true)])[0]
        #expect(snapshot.lastOutcome == nil)
    }

    @Test func jobNamesMatchWithoutTheirExtension() {
        #expect(AppStore.sameJobName("iPad Stand.gcode.3mf", "ipad stand"))
        #expect(AppStore.sameJobName("Bloom Ring.3mf", "Bloom Ring"))
        #expect(!AppStore.sameJobName("Bloom Ring.3mf", "iPad Stand"))
    }
}
