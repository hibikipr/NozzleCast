import Foundation

public struct AMSTraySnapshot: Codable, Sendable {
    public var colorHex: String?
    public var colorAlpha: Double
    public var extraColorHexes: [String]
    public var subtype: String?
    public var effectType: String?
    public var materialLabel: String?

    public init(
        colorHex: String?,
        colorAlpha: Double = 1,
        extraColorHexes: [String] = [],
        subtype: String? = nil,
        effectType: String? = nil,
        materialLabel: String?
    ) {
        self.colorHex = colorHex
        self.colorAlpha = colorAlpha
        self.extraColorHexes = extraColorHexes
        self.subtype = subtype
        self.effectType = effectType
        self.materialLabel = materialLabel
    }
}

public struct AMSUnitSnapshot: Codable, Sendable {
    public var displayName: String
    /// Mirrors `AMSUnit.isHT` — Bambu's high-temperature unit is tagged and styled separately
    /// from numbered AMS units rather than counted alongside them.
    public var isHighTemp: Bool
    public var trays: [AMSTraySnapshot]

    public init(displayName: String, isHighTemp: Bool = false, trays: [AMSTraySnapshot]) {
        self.displayName = displayName
        self.isHighTemp = isHighTemp
        self.trays = trays
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try c.decode(String.self, forKey: .displayName)
        // Tolerate snapshots cached by a previous app version that predates this field.
        isHighTemp = try c.decodeIfPresent(Bool.self, forKey: .isHighTemp) ?? false
        trays = try c.decode([AMSTraySnapshot].self, forKey: .trays)
    }
}

public struct PrinterAMSSnapshot: Codable, Sendable {
    public var printerName: String
    public var stateLabel: String
    public var isPrinting: Bool
    public var amsUnits: [AMSUnitSnapshot]

    public init(printerName: String, stateLabel: String, isPrinting: Bool, amsUnits: [AMSUnitSnapshot]) {
        self.printerName = printerName
        self.stateLabel = stateLabel
        self.isPrinting = isPrinting
        self.amsUnits = amsUnits
    }
}

public enum AMSWidgetStore {
    private static let appGroup = "group.com.victormanuel.NozzleCast"
    private static let key = "amsWidgetSnapshot"
    private static let savedAtKey = "amsWidgetSnapshotSavedAt"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    public static func save(_ snapshots: [PrinterAMSSnapshot]) {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        defaults?.set(data, forKey: key)
        defaults?.set(Date(), forKey: savedAtKey)
    }

    public static func load() -> [PrinterAMSSnapshot] {
        guard let data = defaults?.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([PrinterAMSSnapshot].self, from: data)) ?? []
    }

    /// When the app last wrote a snapshot — drives the widget's "Updated Xm ago" staleness stamp.
    public static var lastSavedAt: Date? {
        defaults?.object(forKey: savedAtKey) as? Date
    }
}
