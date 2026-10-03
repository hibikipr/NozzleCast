import Foundation

/// What the printer is doing, from Bambuddy's `gcode_state` — never overridden by alerts. Like
/// Bambuddy's own printer card, a printer with an active HMS alert still says it's printing or
/// idle, and the alert shows separately (`Printer.alertLevel`); an "Error" state used to replace
/// the phase, so an idle printer with a cleared plate read as broken.
enum PrinterState: String, CaseIterable {
    case printing, paused, idle, finished, failed, offline
}

/// Bambuddy's raw job state, before `PrinterState`'s error/offline overlays collapse it. Kept
/// separate because two surfaces need the underlying phase back: the Live Activity's teardown
/// rule (is there still a job?) and its `stateLabel` (a print with a warning attached is still
/// printing -- the issue belongs on the badge, not in place of the phase).
enum JobPhase: Equatable {
    case printing
    case paused
    /// Reachable, and reporting no job. Distinct from a nil `jobPhase`, which means no reading.
    case idle

    var isActive: Bool { self != .idle }

    /// What the Live Activity should call this phase. Nil for `.idle`, which has no print to label.
    var liveActivityLabel: String? {
        switch self {
        case .printing: String(localized: "Printing", comment: "Live Activity status")
        case .paused: String(localized: "Paused", comment: "Live Activity status")
        case .idle: nil
        }
    }
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

    /// A best-effort name from a raw unit id alone, for when the printer's units aren't loaded:
    /// Bambu numbers regular AMS units from 0 and AMS HT units from 128.
    static func fallbackName(rawID: Int) -> String {
        rawID >= 128
            ? String(localized: "AMS-HT", comment: "Label for Bambu's high-temperature AMS unit")
            : String(localized: "AMS \(rawID + 1)", comment: "Label for a numbered AMS unit, e.g. 'AMS 1'")
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
    /// Bambu's alert level, as Bambuddy reports it since v1.2.5.7 (#2728): 0 invalid, 1 error
    /// (task stopped), 2 warning (task paused), 3 notification (no impact). Older Bambuddy
    /// versions decoded this from the fault's Part ID byte instead, so there it's effectively
    /// arbitrary (a fault that paused a print could read 6).
    var severity: Int
    var description: String?

    enum Tier: Equatable {
        case error, warning
    }

    /// Whether this fault is a real problem worth surfacing, and how bad: a fault that stopped the
    /// task is an error, one that paused it is a warning. Notifications (3) and the invalid level
    /// (0) are nil — they never turn a printer red or badge a Live Activity. Mirrors the relay's
    /// `severityToTier` (nozzlecast-relay `src/hmsIssues.js`) so both writers of the Live
    /// Activity's issue badge agree.
    ///
    /// This used to follow Bambuddy's old labels (severity <= 3 qualifies, <= 2 is an error).
    /// Against the corrected levels that made every paused print read as an error, every
    /// notification as a warning, and an invalid level 0 as a fault.
    var tier: Tier? {
        switch severity {
        case 1: .error
        case 2: .warning
        default: nil
        }
    }

    /// The alert level as shown to the user, including the levels `tier` deliberately ignores.
    enum Level: Int, Comparable {
        /// Ordered most to least severe, so sorting by level puts errors first.
        case error = 0, warning, notification, unknown

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var level: Level {
        switch severity {
        case 1: .error
        case 2: .warning
        case 3: .notification
        default: .unknown
        }
    }

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
    /// What Bambuddy's raw `gcode_state` says this printer is doing, as a job phase: `state`
    /// reports `.offline` for an unreachable printer *before* it ever looks at the gcode state,
    /// and splits a finished job into finished/failed, where the Live Activity only needs to know
    /// whether a job is still running.
    ///
    /// `nil` means "no usable reading" (offline, or the `/status` fetch failed) and is NOT the
    /// same as `.idle` ("reachable, and reports no job") -- see `ActivityTeardown`, which only
    /// tears a Live Activity down on the latter. Conflating the two is what let a single
    /// unreachable poll kill a live print's Live Activity.
    var jobPhase: JobPhase? = nil
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
    /// True only when the printer positively reports Developer LAN mode as off — pause/resume,
    /// stop and homing are then refused by the printer, so the app disables them instead of
    /// letting them fail silently. Unknown (not reported) stays false: nothing is disabled on a
    /// guess.
    var lacksDeveloperMode: Bool = false

    /// Nozzle type/diameter per installed nozzle, ordered left-to-right on dual-nozzle printers.
    var nozzles: [NozzleInfo] = []
    var nozzleRack: [NozzleRackSlot] = []

    /// Accumulated print hours and whether any maintenance item is due, from Bambuddy's
    /// maintenance tracker. Nil when that data hasn't loaded (e.g. offline, still refreshing).
    var totalPrintHours: Double? = nil
    var maintenanceOK: Bool? = nil
    /// Enabled maintenance tasks, most urgent first.
    var maintenanceTasks: [MaintenanceTask] = []

    var smartPlug: SmartPlugInfo? = nil

    /// Obico AI print-failure ("spaghetti") detection — an optional, self-hosted, account-wide
    /// integration, not a native printer feature. `aiDetectionEnabled` is the same for every
    /// printer (it's an account-level toggle); `aiMonitoringActive` is per-printer (only true
    /// while that specific printer currently has a print being watched).
    var aiDetectionEnabled: Bool = false
    var aiMonitoringActive: Bool = false
    var aiLastError: String? = nil

    var isDualNozzle: Bool { nozzles.count > 1 }

    /// The most severe active HMS alert's level, nil with none. Shown beside the state, never in
    /// place of it.
    var alertLevel: HMSError.Level? { hmsErrors.map(\.level).min() }

    /// Worth looking at: an alert that stopped or paused the printer (notifications alone don't
    /// count), or a print that failed. The same "has a problem" Bambuddy's compact card uses.
    var needsAttention: Bool {
        guard state != .offline else { return false }
        return state == .failed || hmsErrors.contains { $0.level == .error || $0.level == .warning }
    }

    /// The clock time the current print should finish, from the remaining minutes.
    var estimatedFinish: Date? {
        etaMinutesRemaining.map { Date().addingTimeInterval(TimeInterval($0) * 60) }
    }

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

/// Bambu-style material names put the base material first and any variant after it — "PLA Matte",
/// "PLA-CF", "PETG HF", "TPU for AMS" — while printers report the plain base ("PLA") for an AMS
/// tray. The family is that first word (split on spaces and hyphens), so a variant matches its
/// base without "Support for PLA" counting as PLA.
enum MaterialFamily {
    static func of(_ material: String) -> String? {
        material.split(whereSeparator: { $0 == " " || $0 == "-" }).first.map { $0.uppercased() }
    }

    static func same(_ a: String, _ b: String) -> Bool {
        guard let fa = of(a), let fb = of(b) else { return false }
        return fa == fb
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
    /// The finish/effect text to append to the material or color name for display — prefers
    /// `effectType` (Bambuddy's own finish label, always a plain lowercase word like "glow"
    /// so `.capitalized` is safe) but falls back to `subtype`, since the edit screen only
    /// exposes a single "Subtype" field and that's where a manually-entered finish like
    /// "Glow" or "Matte" actually lives in practice. `subtype` is used verbatim (no
    /// `.capitalized`) because it can already contain multi-word acronyms like "PLA Basic" or
    /// "PETG HF" that `.capitalized` would mangle into "Pla Basic".
    private var displayEffect: String? {
        if let effectType, !effectType.isEmpty { return effectType.capitalized }
        if let subtype, !subtype.isEmpty { return subtype }
        return nil
    }
    /// The material badge shown on swatches, with the effect/finish appended when present —
    /// e.g. "PLA Glow" vs "PLA Matte" — so otherwise-identical-looking spools of the same
    /// material and color (different Panchroma finishes of the same yellow, say) can be told
    /// apart at a glance instead of relying on the swatch color alone.
    var materialWithEffect: String {
        guard let displayEffect else { return material }
        // A subtype like "PLA Basic" already reads as material + profile — appending it after
        // `material` again would show "PLA PLA Basic".
        if displayEffect.range(of: material, options: .caseInsensitive) != nil { return displayEffect }
        return "\(material) \(displayEffect)"
    }
    /// Bambu's short filament preset id, e.g. "GFL05" — what `configure` calls `tray_info_idx`.
    /// Not editable via a catalog search yet (that's a large separate undertaking); shown/edited
    /// as a raw code for now.
    var slicerFilamentID: String? = nil
    var nozzleTempMin: Int? = nil
    var nozzleTempMax: Int? = nil
    var costPerKg: Double? = nil
    var category: String? = nil
    var note: String? = nil
    /// When Bambuddy archived this spool; nil for an active one. An archived spool's physical
    /// location is no longer meaningful, so `locationCaption` shows this instead.
    var archivedAt: Date? = nil
    /// False when `archivedAt` only marks the spool as archived and isn't a real archive time —
    /// Spoolman mode, where Bambuddy fills it from the spool's last use. The caption then says
    /// just "Archived".
    var archivedDateIsKnown: Bool = true
    /// Below its low-stock alert level — this spool's own override, else the server-wide setting.
    /// Computed when mapped, the same way Bambuddy's inventory page counts "Low Stock".
    var isLowStock: Bool = false
    /// The manufacturer's article/material number.
    var materialNumber: String? = nil
    var suppliers: [SpoolSupplier] = []
    var lastUsedAt: Date? = nil

    var isArchived: Bool { archivedAt != nil }

    var remainingGrams: Int { Int((Double(netWeightGrams) * Double(remainingPercent) / 100).rounded()) }

    /// - Parameters:
    ///   - printerName: Resolves a printer id to its display name.
    ///   - amsUnitName: Resolves (printer id, raw AMS unit id) to the unit's display name —
    ///     `Printer.amsUnitName(amsIndex:)`. Bambuddy's raw unit ids aren't positions: an AMS HT
    ///     unit reports 128+, which the old `amsIndex + 1` turned into "AMS 129".
    func locationCaption(printerName: (String) -> String?, amsUnitName: (String, Int) -> String? = { _, _ in nil }) -> String {
        if let archivedAt {
            guard archivedDateIsKnown else {
                return String(localized: "Archived", comment: "Spool location for an archived spool whose archive date isn't known")
            }
            // The year only when it isn't this year: "Archived · Sep 30", "Archived · Apr 11, 2025".
            let sameYear = Calendar.current.isDate(archivedAt, equalTo: .now, toGranularity: .year)
            let date = archivedAt.formatted(sameYear
                ? .dateTime.month(.abbreviated).day()
                : .dateTime.month(.abbreviated).day().year())
            return String(localized: "Archived · \(date)", comment: "Spool location for an archived spool, with the date it was archived")
        }
        switch location {
        case .storage(let name):
            if let name {
                return String(localized: "In storage · \(name)", comment: "Spool location: a named storage location")
            }
            return String(localized: "In storage", comment: "Spool location: unnamed storage")
        case .ams(let printerID, let amsIndex, let trayIndex):
            let name = printerName(printerID) ?? String(localized: "Printer", comment: "Fallback name for a printer with no known name")
            let unitName = amsUnitName(printerID, amsIndex) ?? AMSUnit.fallbackName(rawID: amsIndex)
            let slotLabel = String(localized: "\(unitName) · Slot \(trayIndex + 1)", comment: "AMS unit name and slot number, e.g. 'AMS 1 · Slot 3' or 'AMS-HT · Slot 1'")
            return String(localized: "\(name) · \(slotLabel)", comment: "Spool location: printer name and AMS slot")
        }
    }
}

extension Printer {
    /// The display name of this printer's AMS unit with the given raw id — the same naming every
    /// AMS screen uses: regular units numbered by their order among the regular units ("AMS 1",
    /// "AMS 2"), an AMS HT unit labelled "AMS-HT" regardless of its raw id (128+).
    func amsUnitName(amsIndex: Int) -> String? {
        guard let unit = amsUnits.first(where: { $0.index == amsIndex }) else { return nil }
        let position = amsUnits.filter { !$0.isHT }.firstIndex { $0.index == amsIndex } ?? 0
        return unit.displayName(position: position)
    }
}

/// A recurring maintenance task on a printer (lubricate rails, clean the nozzle, …) from
/// Bambuddy's maintenance tracker. Bambuddy decides when it's due; the app only shows it and
/// records it as done.
struct MaintenanceTask: Identifiable, Equatable {
    enum Interval: Equatable {
        /// Every so many print hours.
        case printHours(Double)
        /// Every so many calendar days.
        case days(Double)
    }

    var id: Int
    var name: String
    var symbol: String
    var wikiURL: URL?
    var interval: Interval
    /// Print hours or days (matching `interval`) since it was last done.
    var elapsed: Double
    /// Print hours or days (matching `interval`) left until due; negative once overdue.
    var remaining: Double
    var isDue: Bool
    var isWarning: Bool
    var lastPerformedAt: Date?

    /// How much of the interval has passed, 0...1.
    var progress: Double {
        let length: Double
        switch interval {
        case .printHours(let hours): length = hours
        case .days(let days): length = days
        }
        guard length > 0 else { return 1 }
        return min(1, max(0, elapsed / length))
    }

    /// Lucide icon names Bambuddy's default task types use, as SF Symbols.
    static func symbol(forLucideIcon icon: String?) -> String {
        switch icon?.lowercased() {
        case "droplet", "droplets": "drop.fill"
        case "sparkles": "sparkles"
        case "flame": "flame.fill"
        case "ruler": "ruler.fill"
        case "square": "square.fill"
        case "cable": "cable.connector"
        case "fan": "fan.fill"
        case "wind": "wind"
        case "filter": "line.3.horizontal.decrease"
        case "thermometer": "thermometer.medium"
        case "cog", "settings": "gearshape.fill"
        case "zap": "bolt.fill"
        case "eye": "eye.fill"
        case "scissors": "scissors"
        default: "wrench.and.screwdriver.fill"
        }
    }
}
