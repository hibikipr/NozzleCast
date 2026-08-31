import SwiftUI
import Observation

@Observable
final class AppStore {
    var printers: [Printer]
    var spools: [Spool]

    init(printers: [Printer], spools: [Spool]) {
        self.printers = printers
        self.spools = spools
    }

    func printer(_ id: UUID) -> Printer? {
        printers.first { $0.id == id }
    }

    func printerName(_ id: UUID) -> String? {
        printer(id)?.name
    }

    func spool(_ id: UUID?) -> Spool? {
        guard let id else { return nil }
        return spools.first { $0.id == id }
    }

    func spool(inSlot slot: Int, of printerID: UUID) -> Spool? {
        guard let printer = printer(printerID), slot < printer.amsSlotSpoolIDs.count,
              let spoolID = printer.amsSlotSpoolIDs[slot] else { return nil }
        return spool(spoolID)
    }

    // MARK: - Printer controls

    func togglePause(_ printerID: UUID) {
        guard let idx = printers.firstIndex(where: { $0.id == printerID }) else { return }
        switch printers[idx].state {
        case .printing: printers[idx].state = .paused
        case .paused, .idle: printers[idx].state = .printing
        default: break
        }
    }

    func stop(_ printerID: UUID) {
        guard let idx = printers.firstIndex(where: { $0.id == printerID }) else { return }
        printers[idx].state = .idle
        printers[idx].jobFileName = nil
        printers[idx].progress = nil
        printers[idx].etaMinutesRemaining = nil
    }

    func toggleLight(_ printerID: UUID) {
        guard let idx = printers.firstIndex(where: { $0.id == printerID }) else { return }
        printers[idx].lightOn.toggle()
    }

    // MARK: - AMS assignment

    func assign(spoolID: UUID, toPrinter printerID: UUID, slot: Int) {
        // Clear this spool from any AMS slot it currently occupies.
        for i in printers.indices {
            for s in printers[i].amsSlotSpoolIDs.indices where printers[i].amsSlotSpoolIDs[s] == spoolID {
                printers[i].amsSlotSpoolIDs[s] = nil
            }
        }
        guard let idx = printers.firstIndex(where: { $0.id == printerID }) else { return }
        printers[idx].amsSlotSpoolIDs[slot] = spoolID

        if let sIdx = spools.firstIndex(where: { $0.id == spoolID }) {
            spools[sIdx].location = .ams(printerID: printerID, slot: slot)
        }
    }

    func unassign(printerID: UUID, slot: Int) {
        guard let idx = printers.firstIndex(where: { $0.id == printerID }) else { return }
        guard let spoolID = printers[idx].amsSlotSpoolIDs[slot] else { return }
        printers[idx].amsSlotSpoolIDs[slot] = nil
        if let sIdx = spools.firstIndex(where: { $0.id == spoolID }) {
            spools[sIdx].location = .storage
        }
    }

    // MARK: - Inventory

    @discardableResult
    func addSpool(material: FilamentMaterial, colorName: String, colorHex: String, brand: String, netWeightGrams: Int) -> Spool {
        let spool = Spool(
            id: UUID(),
            material: material,
            colorName: colorName,
            colorHex: colorHex,
            brand: brand,
            remainingPercent: 100,
            netWeightGrams: netWeightGrams,
            location: .storage
        )
        spools.insert(spool, at: 0)
        return spool
    }
}
