import Foundation

enum PrinterState: String, CaseIterable {
    case printing, paused, idle, error, offline
}

struct TemperatureReading: Equatable {
    var current: Int
    var target: Int?
}

/// One physical filament slot: `amsIndex` identifies the AMS unit (a printer may have more than one),
/// `trayIndex` the slot within that unit.
struct AMSTray: Identifiable, Equatable {
    var amsIndex: Int
    var trayIndex: Int
    var spoolID: String?

    /// The printer itself reports a spool is physically loaded (color/type read off the RFID
    /// tag or entered manually) even when nothing in Bambuddy's inventory has been linked to
    /// it yet — that's a distinct state from a slot that's genuinely empty.
    var isLoaded: Bool = false
    var rawColorHex: String?
    var rawMaterialLabel: String?

    /// True when the printer reports a spool physically loaded but it hasn't been matched to
    /// an inventory spool — Bambuddy's own "Assign Spool" case.
    var needsAssignment: Bool { isLoaded && spoolID == nil }

    var id: String { "\(amsIndex)-\(trayIndex)" }
}

struct AMSUnit: Identifiable, Equatable {
    var index: Int
    var trays: [AMSTray]
    var isHT: Bool = false
    var humidity: Int?
    var temperature: Double?
    /// Which physical nozzle this unit feeds on a dual-nozzle printer, from Bambuddy's
    /// `ams_switch_inlet` mapping ("A" = left, "B" = right). Nil on single-nozzle printers
    /// or when the printer hasn't reported a mapping.
    var feedsRightNozzle: Bool?

    var isDrying: Bool = false
    var dryTargetTemp: Int?
    var dryFilament: String?

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
struct NozzleRackSlot: Identifiable, Equatable {
    var id: Int
    var diameter: String
    var maxTemp: Int
    var isEmpty: Bool
    var filamentColorHex: String?
}

struct NozzleInfo: Identifiable, Equatable {
    var index: Int
    var type: String
    var diameter: String

    var id: Int { index }
}

struct HMSError: Identifiable, Equatable {
    var id: String { fullCode }
    var fullCode: String
    var severity: Int
    var description: String?

    /// The code grouped into Bambu's standard four 4-hex-digit fields (module/type/subtype/code),
    /// e.g. "0500-0500-0001-0007" — this is also the form the Bambu wiki keys its HMS lookup
    /// pages on. Nil if `fullCode` isn't the expected 16 hex digits.
    var dashedCode: String? {
        guard fullCode.count == 16, fullCode.allSatisfy(\.isHexDigit) else { return nil }
        let groups = stride(from: 0, to: 16, by: 4).map { offset -> Substring in
            let start = fullCode.index(fullCode.startIndex, offsetBy: offset)
            let end = fullCode.index(start, offsetBy: 4)
            return fullCode[start..<end]
        }
        return groups.joined(separator: "-")
    }

    /// Bambu's own HMS codes always display grouped this way — `fullCode` arrives as one
    /// 16-digit run with no separators, which reads as a meaningless giant number when shown
    /// as-is (e.g. with no human-readable description available).
    var displayCode: String {
        dashedCode.map { "HMS " + $0 } ?? fullCode
    }
}

struct FanSpeeds: Equatable {
    var partCooling: Int?
    var auxiliary: Int?
    var chamber: Int?
}

struct SmartPlugInfo: Equatable {
    var id: Int
    var name: String
    var isOn: Bool
    var watts: Double?
}

struct Printer: Identifiable, Equatable {
    let id: String
    var name: String
    var model: String
    var imageAssetName: String?
    var state: PrinterState
    var jobFileName: String?
    var progress: Double?
    var etaMinutesRemaining: Int?
    var currentLayer: Int? = nil
    var totalLayers: Int? = nil
    /// Extra detail about what the printer is actually doing right now, beyond `state` — e.g.
    /// "Purifying the chamber air" during the post-print chamber-purification cycle that runs
    /// after progress hits 100% but before `state` leaves `.printing`. Nil whenever there's
    /// nothing more specific to say than `state.label` already does. See `mapPrinter` for how
    /// this is derived and filtered from Bambuddy's `stg_cur_name`.
    var stageDetail: String? = nil
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
    var awaitingPlateClear: Bool = false

    /// Nozzle type/diameter per installed nozzle, ordered left-to-right on dual-nozzle printers.
    var nozzles: [NozzleInfo] = []
    var nozzleRack: [NozzleRackSlot] = []

    /// Accumulated print hours and whether any maintenance item is due, from Bambuddy's
    /// maintenance tracker. Nil when that data hasn't loaded (e.g. offline, still refreshing).
    var totalPrintHours: Double? = nil
    var maintenanceOK: Bool? = nil

    var smartPlug: SmartPlugInfo? = nil

    /// Obico AI print-failure ("spaghetti") detection — an optional, self-hosted, account-wide
    /// integration, not a native printer feature. `aiDetectionEnabled` is the same for every
    /// printer (it's an account-level toggle); `aiMonitoringActive` is per-printer (only true
    /// while that specific printer currently has a print being watched).
    var aiDetectionEnabled: Bool = false
    var aiMonitoringActive: Bool = false
    var aiLastError: String? = nil

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

struct Spool: Identifiable, Equatable {
    let id: String
    /// The raw material string, e.g. "PLA", "PETG-HF", "PC" — Bambuddy accepts any value here,
    /// not a fixed set, so this isn't `FilamentMaterial` (that enum is a coarse bucketing
    /// helper for filtering/matching, not the source of truth for what a spool actually is).
    var material: String
    var colorName: String
    var colorHex: String
    /// Alpha channel from Bambuddy's `rgba` field (the 4th RRGGBB**AA** byte), 0...1. Bambuddy
    /// has no separate "is translucent" flag — a spool reads as translucent purely because this
    /// is less than 1, which the swatch renders over a checkerboard so it actually looks clear
    /// instead of a flat, muddy color. 1 for a fully opaque spool (the vast majority).
    var colorAlpha: Double = 1
    /// Additional hex color stops beyond `colorHex` — a dual/multi-color or gradient-effect
    /// spool (Bambuddy's "Extra colors" field). Empty for a plain single-color spool.
    var extraColorHexes: [String] = []
    var brand: String
    var remainingPercent: Int
    var netWeightGrams: Int
    var location: SpoolLocation

    /// Sub-brand/profile name, e.g. "PLA Basic", "PETG HF" — Bambu's `tray_sub_brands`. Also
    /// doubles as Bambuddy's multi-color marker: a value of "Multicolor" means `extraColorHexes`
    /// should render as a pie wheel rather than a blended gradient.
    var subtype: String? = nil
    /// Bambuddy's finish/effect label for the swatch overlay — "sparkle", "silk", "matte",
    /// "wood", "marble", "glow", "galaxy", "metal", "translucent", "rainbow", or nil for a plain
    /// filament. Purely cosmetic; "translucent" itself paints nothing extra since the look
    /// already comes from `colorAlpha` — it's a categorical label only.
    var effectType: String? = nil
    /// Bambu's short filament preset id, e.g. "GFL05" — what `configure` calls `tray_info_idx`.
    /// Not editable via a catalog search yet (that's a large separate undertaking); shown/edited
    /// as a raw code for now.
    var slicerFilamentID: String? = nil
    var nozzleTempMin: Int? = nil
    var nozzleTempMax: Int? = nil
    var costPerKg: Double? = nil
    var category: String? = nil
    var note: String? = nil

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
