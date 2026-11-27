import Foundation
import Testing
@testable import NozzleCast

/// The H3C's AMS 3H and the P3C's AMS 3P number their slots from a base, not `unit * 4 + slot`
/// (Bambuddy's `utils/tray_ids.py`), and `tray_now` arrives in that numbering.
struct RackAMSTests {
    private func tray(_ unit: Int, _ slot: Int, type: Int? = nil) -> AMSTray {
        AMSTray(amsIndex: unit, trayIndex: slot, spoolID: nil, amsType: type)
    }

    @Test func ams3PSlotsAreNumberedFrom37() {
        #expect((0..<7).map { tray(33, $0, type: 7).globalID() } == [37, 38, 39, 40, 41, 42, 43])
    }

    @Test func ams3HSlotsAreNumberedFrom28() {
        #expect((0..<9).map { tray(32, $0, type: 6).globalID() } == Array(28...36))
    }

    @Test func rackKindFallsBackToTheUnitIdWithoutAType() {
        #expect(tray(33, 2).globalID() == 39)
        #expect(tray(32, 0).globalID() == 28)
        #expect(RackAMS.of(unitID: 33, amsType: nil) == .ams3P)
        #expect(RackAMS.of(unitID: 32, amsType: nil) == .ams3H)
    }

    @Test func aTypeOverridesTheUnitId() {
        // Bambuddy says what the unit is: a regular AMS (type 1) is never a rack, whatever its id.
        #expect(RackAMS.of(unitID: 33, amsType: 1) == nil)
        #expect(RackAMS.of(unitID: 5, amsType: 7) == .ams3P)
        #expect(RackAMS.of(unitID: 5, amsType: 6) == .ams3H)
    }

    @Test func regularAndHighTempUnitsKeepTheirNumbering() {
        #expect(tray(0, 0, type: 1).globalID() == 0)
        #expect(tray(2, 3, type: 1).globalID() == 11)
        #expect(tray(129, 0, type: 4).globalID() == 129)
        #expect(tray(6, 1, type: 5).globalID() == 25) // the A2L's AMS Lite, stored as unit 6
    }

    @Test func externalInputsUseTheIdBambuddyReports() {
        var rackInput = AMSTray(amsIndex: -1, trayIndex: 2, spoolID: nil)
        rackInput.externalGlobalID = 249
        #expect(rackInput.globalID(isExternal: true) == 249)
        var main = AMSTray(amsIndex: -1, trayIndex: 1, spoolID: nil)
        main.externalGlobalID = 255
        #expect(main.globalID(isExternal: true) == 255)
        // Without a reported id the old rule still holds.
        #expect(AMSTray(amsIndex: -1, trayIndex: 0, spoolID: nil).globalID(isExternal: true) == 254)
        #expect(AMSTray(amsIndex: -1, trayIndex: 1, spoolID: nil).globalID(isExternal: true) == 255)
    }

    @Test func rackUnitsAreNamedForTheirModelAndDoNotTakeANumber() {
        let printer = Printer(
            id: "p", name: "P3C", model: "P3C", state: .idle,
            nozzle: TemperatureReading(current: 25, target: nil),
            bed: TemperatureReading(current: 25, target: nil),
            lightOn: false,
            amsUnits: [
                AMSUnit(index: 33, trays: [], amsType: 7),
                AMSUnit(index: 0, trays: [], amsType: 1),
            ]
        )
        #expect(printer.amsUnitName(amsIndex: 33) == "AMS 3P")
        #expect(printer.amsUnitName(amsIndex: 0) == "AMS 1")
        #expect(RackAMS.ams3P.slotCount == 7)
        #expect(RackAMS.ams3H.slotCount == 9)
    }
}

/// A job that waits because a spool is too short can be released with "Print Anyway"
/// (Bambuddy 1.3.3b1, #3659); one whose filament isn't loaded at all cannot.
struct PrintAnywayWaitTests {
    @Test func readsAShortSpool() {
        #expect(QueuedPrint.isShortFilamentWait("Waiting for filament: PLA (20 g left, needs 300 g)"))
        #expect(QueuedPrint.isShortFilamentWait("Waiting for filament: PLA (needs 300 g)"))
        #expect(QueuedPrint.isShortFilamentWait("Waiting for filament: P1 (needs more filament)"))
        #expect(QueuedPrint.isShortFilamentWait("Busy: Office | Waiting for filament: PETG (5 g left, needs 80 g) · priority in 2 h"))
    }

    @Test func ignoresFilamentThatIsNotLoadedAndOtherReasons() {
        #expect(!QueuedPrint.isShortFilamentWait("Waiting for filament: PLA #FFFFFF"))
        #expect(!QueuedPrint.isShortFilamentWait("Waiting for filament: P1 (needs PLA #FFFFFF)"))
        #expect(!QueuedPrint.isShortFilamentWait("Busy: Office P1S"))
        #expect(!QueuedPrint.isShortFilamentWait("(needs 300 g)"))
        #expect(!QueuedPrint.isShortFilamentWait(""))
        #expect(!QueuedPrint.isShortFilamentWait(nil))
    }

    private func job(staged: Bool, status: QueuedPrint.Status = .pending, reason: String?) -> QueuedPrint {
        QueuedPrint(id: "q-1", bambuddyID: 1, name: "Clip", destination: "Any P1S", status: status, position: 1, isStaged: staged, waitingReason: reason)
    }

    @Test func onlyAnUnstagedPendingJobGetsPrintAnyway() {
        let short = "Waiting for filament: PLA (needs 300 g)"
        #expect(job(staged: false, reason: short).waitsForShortFilament)
        #expect(!job(staged: true, reason: short).waitsForShortFilament) // has Start already
        #expect(!job(staged: false, status: .printing, reason: short).waitsForShortFilament)
        #expect(!job(staged: false, reason: nil).waitsForShortFilament)
    }
}
