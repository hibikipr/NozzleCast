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
    public var trays: [AMSTraySnapshot]

    public init(displayName: String, trays: [AMSTraySnapshot]) {
        self.displayName = displayName
        self.trays = trays
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

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    public static func save(_ snapshots: [PrinterAMSSnapshot]) {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        defaults?.set(data, forKey: key)
    }

    public static func load() -> [PrinterAMSSnapshot] {
        guard let data = defaults?.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([PrinterAMSSnapshot].self, from: data)) ?? []
    }
}
