import Foundation

enum PrinterState: String, CaseIterable {
    case printing, paused, idle, error, offline
}

struct TemperatureReading {
    var current: Int
    var target: Int?
}

/// One physical filament slot: `amsIndex` identifies the AMS unit (a printer may have more than one),
/// `trayIndex` the slot within that unit.
struct AMSTray: Identifiable {
    var amsIndex: Int
    var trayIndex: Int
    var spoolID: String?

    var id: String { "\(amsIndex)-\(trayIndex)" }
}

struct AMSUnit: Identifiable {
    var index: Int
    var trays: [AMSTray]
    var isHT: Bool = false

    var id: Int { index }

    /// Bambu's high-temperature AMS unit carries an unrelated raw unit id (e.g. 129), so it
    /// gets a fixed label instead of being numbered alongside the regular AMS units.
    func displayName(position: Int) -> String {
        isHT ? "AMS-HT" : "AMS \(position + 1)"
    }
}

struct Printer: Identifiable {
    let id: String
    var name: String
    var model: String
    var imageAssetName: String?
    var state: PrinterState
    var jobFileName: String?
    var progress: Double?
    var etaMinutesRemaining: Int?
    var nozzle: TemperatureReading
    var bed: TemperatureReading
    var chamber: TemperatureReading?
    var lightOn: Bool
    var amsUnits: [AMSUnit]

    var etaDescription: String? {
        guard let minutes = etaMinutesRemaining else { return nil }
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    var statusSubtitle: String { "\(model) · \(state.label)" }

    /// Flat list of every tray across every AMS unit, in display order.
    var allTrays: [AMSTray] { amsUnits.flatMap(\.trays) }
}

enum FilamentMaterial: String, CaseIterable, Identifiable {
    case pla = "PLA"
    case petg = "PETG"
    case abs = "ABS"
    case tpu = "TPU"

    var id: String { rawValue }

    /// Best-effort match against a Bambuddy material string (e.g. "PLA", "PETG-HF", "Support for PLA").
    static func from(bambuddyMaterial: String) -> FilamentMaterial {
        let upper = bambuddyMaterial.uppercased()
        if upper.contains("PETG") { return .petg }
        if upper.contains("ABS") || upper.contains("ASA") { return .abs }
        if upper.contains("TPU") { return .tpu }
        return .pla
    }
}

enum SpoolLocation: Equatable {
    case ams(printerID: String, amsIndex: Int, trayIndex: Int)
    case storage(name: String?)
}

struct Spool: Identifiable {
    let id: String
    var material: FilamentMaterial
    var colorName: String
    var colorHex: String
    var brand: String
    var remainingPercent: Int
    var netWeightGrams: Int
    var location: SpoolLocation

    func locationCaption(printerName: (String) -> String?) -> String {
        switch location {
        case .storage(let name):
            return name.map { "In storage · \($0)" } ?? "In storage"
        case .ams(let printerID, let amsIndex, let trayIndex):
            let name = printerName(printerID) ?? "Printer"
            let slotLabel = "AMS \(amsIndex + 1) · Slot \(trayIndex + 1)"
            return "\(name) · \(slotLabel)"
        }
    }
}
