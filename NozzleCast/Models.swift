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
    var humidity: Int?
    var temperature: Double?
    /// Which physical nozzle this unit feeds on a dual-nozzle printer, from Bambuddy's
    /// `ams_switch_inlet` mapping ("A" = left, "B" = right). Nil on single-nozzle printers
    /// or when the printer hasn't reported a mapping.
    var feedsRightNozzle: Bool?

    var id: Int { index }

    /// Bambu's high-temperature AMS unit carries an unrelated raw unit id (e.g. 129), so it
    /// gets a fixed label instead of being numbered alongside the regular AMS units.
    func displayName(position: Int) -> String {
        isHT
            ? String(localized: "AMS-HT", comment: "Label for Bambu's high-temperature AMS unit")
            : String(localized: "AMS \(position + 1)", comment: "Label for a numbered AMS unit, e.g. 'AMS 1'")
    }
}

/// A physical spool bay on a dual-nozzle printer's automatic nozzle-changer rack.
struct NozzleRackSlot: Identifiable {
    var id: Int
    var diameter: String
    var maxTemp: Int
    var isEmpty: Bool
    var filamentColorHex: String?
}

struct NozzleInfo: Identifiable {
    var index: Int
    var type: String
    var diameter: String

    var id: Int { index }
}

struct HMSError: Identifiable {
    var id: String { fullCode }
    var fullCode: String
    var severity: Int
    var description: String?
}

struct FanSpeeds {
    var partCooling: Int?
    var auxiliary: Int?
    var chamber: Int?
}

struct SmartPlugInfo {
    var id: Int
    var name: String
    var isOn: Bool
    var watts: Double?
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
    /// Second nozzle's reading on a dual-nozzle printer (e.g. the H2C); nil everywhere else.
    var rightNozzle: TemperatureReading? = nil
    var bed: TemperatureReading
    var chamber: TemperatureReading?
    var lightOn: Bool
    var amsUnits: [AMSUnit]
    /// Spool bays fed directly (not through an AMS) — index 0 is the left/primary nozzle's,
    /// index 1 (if present) the right nozzle's.
    var externalTrays: [AMSTray] = []

    var wifiSignalDBm: Int? = nil
    var firmwareVersion: String? = nil
    var hmsErrors: [HMSError] = []
    var doorOpen: Bool = false
    var fanSpeeds: FanSpeeds = FanSpeeds()
    var coverURL: URL? = nil
    var awaitingPlateClear: Bool = false

    /// Nozzle type/diameter per installed nozzle, ordered left-to-right on dual-nozzle printers.
    var nozzles: [NozzleInfo] = []
    var nozzleRack: [NozzleRackSlot] = []

    /// Accumulated print hours and whether any maintenance item is due, from Bambuddy's
    /// maintenance tracker. Nil when that data hasn't loaded (e.g. offline, still refreshing).
    var totalPrintHours: Double? = nil
    var maintenanceOK: Bool? = nil

    var smartPlug: SmartPlugInfo? = nil

    var isDualNozzle: Bool { nozzles.count > 1 }

    var etaDescription: String? {
        guard let minutes = etaMinutesRemaining else { return nil }
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 {
            return String(localized: "\(h)h \(m)m", comment: "Remaining print time, hours and minutes")
        }
        return String(localized: "\(m)m", comment: "Remaining print time, minutes only")
    }

    var statusSubtitle: String {
        String(localized: "\(model) · \(state.label)", comment: "Printer model and status, e.g. 'X1 Carbon · Printing'")
    }

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
            if let name {
                return String(localized: "In storage · \(name)", comment: "Spool location: a named storage location")
            }
            return String(localized: "In storage", comment: "Spool location: unnamed storage")
        case .ams(let printerID, let amsIndex, let trayIndex):
            let name = printerName(printerID) ?? String(localized: "Printer", comment: "Fallback name for a printer with no known name")
            let slotLabel = String(localized: "AMS \(amsIndex + 1) · Slot \(trayIndex + 1)", comment: "AMS unit and slot number, e.g. 'AMS 1 · Slot 3'")
            return String(localized: "\(name) · \(slotLabel)", comment: "Spool location: printer name and AMS slot")
        }
    }
}
