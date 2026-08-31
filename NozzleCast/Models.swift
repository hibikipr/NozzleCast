import Foundation

enum PrinterState: String, CaseIterable {
    case printing, paused, idle, error, offline
}

struct TemperatureReading {
    var current: Int
    var target: Int?
}

struct Printer: Identifiable {
    let id: UUID
    var name: String
    var model: String
    var imageAssetName: String
    var state: PrinterState
    var jobFileName: String?
    var progress: Double?
    var etaMinutesRemaining: Int?
    var nozzle: TemperatureReading
    var bed: TemperatureReading
    var chamber: TemperatureReading?
    var lightOn: Bool
    var amsSlotSpoolIDs: [UUID?]

    var etaDescription: String? {
        guard let minutes = etaMinutesRemaining else { return nil }
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    var statusSubtitle: String { "\(model) · \(state.label)" }
}

enum FilamentMaterial: String, CaseIterable, Identifiable {
    case pla = "PLA"
    case petg = "PETG"
    case abs = "ABS"
    case tpu = "TPU"

    var id: String { rawValue }
}

enum SpoolLocation: Equatable {
    case ams(printerID: UUID, slot: Int)
    case storage
}

struct Spool: Identifiable {
    let id: UUID
    var material: FilamentMaterial
    var colorName: String
    var colorHex: String
    var brand: String
    var remainingPercent: Int
    var netWeightGrams: Int
    var location: SpoolLocation

    func locationCaption(printerName: (UUID) -> String?) -> String {
        switch location {
        case .storage:
            return "In storage"
        case .ams(let printerID, let slot):
            let name = printerName(printerID) ?? "Printer"
            return "\(name) · Slot \(slot + 1)"
        }
    }
}
