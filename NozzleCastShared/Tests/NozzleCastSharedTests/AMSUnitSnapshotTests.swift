import Foundation
import Testing
@testable import NozzleCastShared

/// The AMS widgets draw a regular AMS unit's four slots, but a rack printer's own AMS (the H3C's
/// AMS 3H, the P3C's AMS 3P) has one slot per hotend: nine and seven.
struct AMSUnitSnapshotTests {
    private func trays(_ count: Int) -> [AMSTraySnapshot] {
        (0..<count).map { AMSTraySnapshot(colorHex: "#E8622C", materialLabel: "PLA", isFeeding: $0 == 4) }
    }

    @Test func aRackUnitShowsEverySlot() {
        #expect(AMSUnitSnapshot(displayName: "AMS 3P", isRack: true, trays: trays(7)).visibleTrays.count == 7)
        #expect(AMSUnitSnapshot(displayName: "AMS 3H", isRack: true, trays: trays(9)).visibleTrays.count == 9)
    }

    @Test func aRegularUnitStopsAtFourSlots() {
        #expect(AMSUnitSnapshot(displayName: "AMS 1", trays: trays(4)).visibleTrays.count == 4)
        #expect(AMSUnitSnapshot(displayName: "AMS 1", trays: trays(7)).visibleTrays.count == 4)
        #expect(AMSUnitSnapshot(displayName: "AMS-HT", isHighTemp: true, trays: trays(1)).visibleTrays.count == 1)
    }

    @Test func theFeedingSlotPastTheFourthSurvives() {
        let unit = AMSUnitSnapshot(displayName: "AMS 3P", isRack: true, trays: trays(7))
        #expect(unit.visibleTrays.firstIndex { $0.isFeeding == true } == 4)
    }

    @Test func aSnapshotCachedBeforeRackUnitsStillLoads() throws {
        let json = #"{"displayName":"AMS 1","isHighTemp":false,"trays":[]}"#
        let unit = try JSONDecoder().decode(AMSUnitSnapshot.self, from: Data(json.utf8))
        #expect(unit.isRack == false)
        #expect(unit.displayName == "AMS 1")
    }

    @Test func theRackFlagSurvivesAnEncodeAndDecode() throws {
        let unit = AMSUnitSnapshot(displayName: "AMS 3P", isRack: true, trays: trays(7))
        let decoded = try JSONDecoder().decode(AMSUnitSnapshot.self, from: JSONEncoder().encode(unit))
        #expect(decoded.isRack)
        #expect(decoded.trays.count == 7)
    }
}
