import Foundation

/// One printer's current print, as the app hands it to the Print Status widget through the App Group.
public struct PrintStatusSnapshot: Codable, Sendable, Equatable {
    /// `PrintActivityAttributes.normalizedID(printer.name)`: the stable key a widget stores for "this printer".
    public var printerID: String
    public var printerName: String
    public var stateLabel: String
    /// A job is loaded (printing, paused, preparing). False when idle, finished or offline.
    public var isActive: Bool
    /// Printer-reported, 0...1.
    public var progress: Double
    public var jobName: String?
    public var startedAt: Date
    public var estimatedEndAt: Date?
    public var currentLayer: Int?
    public var totalLayers: Int?
    public var nozzleTempC: Int?
    public var rightNozzleTempC: Int?
    public var bedTempC: Int?
    /// "error" | "warning" | nil
    public var issueSeverity: String?
    public var issueCount: Int?
    public var stageDetail: String?
    /// When idle: the last print's job name, used to find its saved cover.
    public var lastJobName: String?
    /// When idle: when that last print ended.
    public var finishedAt: Date?
    /// When idle: how that last print ended, so a failed one doesn't read as "Finished".
    public var lastOutcome: Outcome?

    public enum Outcome: String, Codable, Sendable {
        case completed, failed, cancelled
    }

    public init(
        printerID: String,
        printerName: String,
        stateLabel: String = "",
        isActive: Bool = false,
        progress: Double = 0,
        jobName: String? = nil,
        startedAt: Date = .distantPast,
        estimatedEndAt: Date? = nil,
        currentLayer: Int? = nil,
        totalLayers: Int? = nil,
        nozzleTempC: Int? = nil,
        rightNozzleTempC: Int? = nil,
        bedTempC: Int? = nil,
        issueSeverity: String? = nil,
        issueCount: Int? = nil,
        stageDetail: String? = nil,
        lastJobName: String? = nil,
        finishedAt: Date? = nil,
        lastOutcome: Outcome? = nil
    ) {
        self.printerID = printerID
        self.printerName = printerName
        self.stateLabel = stateLabel
        self.isActive = isActive
        self.progress = progress
        self.jobName = jobName
        self.startedAt = startedAt
        self.estimatedEndAt = estimatedEndAt
        self.currentLayer = currentLayer
        self.totalLayers = totalLayers
        self.nozzleTempC = nozzleTempC
        self.rightNozzleTempC = rightNozzleTempC
        self.bedTempC = bedTempC
        self.issueSeverity = issueSeverity
        self.issueCount = issueCount
        self.stageDetail = stageDetail
        self.lastJobName = lastJobName
        self.finishedAt = finishedAt
        self.lastOutcome = lastOutcome
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        printerID = try c.decode(String.self, forKey: .printerID)
        printerName = try c.decode(String.self, forKey: .printerName)
        // Everything else tolerates snapshots written by an earlier or later app version.
        stateLabel = try c.decodeIfPresent(String.self, forKey: .stateLabel) ?? ""
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        jobName = try c.decodeIfPresent(String.self, forKey: .jobName)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? .distantPast
        estimatedEndAt = try c.decodeIfPresent(Date.self, forKey: .estimatedEndAt)
        currentLayer = try c.decodeIfPresent(Int.self, forKey: .currentLayer)
        totalLayers = try c.decodeIfPresent(Int.self, forKey: .totalLayers)
        nozzleTempC = try c.decodeIfPresent(Int.self, forKey: .nozzleTempC)
        rightNozzleTempC = try c.decodeIfPresent(Int.self, forKey: .rightNozzleTempC)
        bedTempC = try c.decodeIfPresent(Int.self, forKey: .bedTempC)
        issueSeverity = try c.decodeIfPresent(String.self, forKey: .issueSeverity)
        issueCount = try c.decodeIfPresent(Int.self, forKey: .issueCount)
        stageDetail = try c.decodeIfPresent(String.self, forKey: .stageDetail)
        lastJobName = try c.decodeIfPresent(String.self, forKey: .lastJobName)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        // `try?`: an outcome a later version adds decodes as unknown rather than failing the snapshot.
        lastOutcome = (try? c.decodeIfPresent(Outcome.self, forKey: .lastOutcome)) ?? nil
    }
}

public enum PrintStatusWidgetStore {
    private static let appGroup = "group.com.victormanuel.NozzleCast"
    private static let key = "printStatusWidgetSnapshot"
    private static let savedAtKey = "printStatusWidgetSnapshotSavedAt"

    /// Tests on macOS have no App Group, so they inject a plain `UserDefaults` here.
    nonisolated(unsafe) static var defaultsOverride: UserDefaults?

    private static var defaults: UserDefaults? {
        defaultsOverride ?? UserDefaults(suiteName: appGroup)
    }

    public static func save(_ snapshots: [PrintStatusSnapshot]) {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        defaults?.set(data, forKey: key)
        defaults?.set(Date(), forKey: savedAtKey)
    }

    /// Empty when nothing was saved or the data can't be decoded, so the widget shows its empty state.
    public static func load() -> [PrintStatusSnapshot] {
        guard let data = defaults?.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([PrintStatusSnapshot].self, from: data)) ?? []
    }

    /// When the app last wrote a snapshot, for the widget's staleness stamp.
    public static var lastSavedAt: Date? {
        defaults?.object(forKey: savedAtKey) as? Date
    }
}

extension PrintStatusSnapshot {
    /// The user's chosen printer when it's present; otherwise the automatic choice. A widget pinned to a
    /// printer that was since removed falls back rather than going blank.
    public static func pick(_ snapshots: [PrintStatusSnapshot], printerID: String?, now: Date = .now) -> PrintStatusSnapshot? {
        if let printerID, let match = snapshots.first(where: { $0.printerID == printerID }) {
            return match
        }
        return ranked(snapshots, now: now).first
    }

    /// Most useful first: prints about to finish, then other active prints, then idle printers by recency.
    public static func ranked(_ snapshots: [PrintStatusSnapshot], now: Date = .now) -> [PrintStatusSnapshot] {
        func tier(_ s: PrintStatusSnapshot) -> Int {
            guard s.isActive else { return 2 }
            if let end = s.estimatedEndAt, end > now { return 0 }
            return 1
        }
        return snapshots.sorted { a, b in
            let ta = tier(a), tb = tier(b)
            if ta != tb { return ta < tb }
            switch ta {
            case 0:
                // Both tiers-0 have a future estimate.
                let ea = a.estimatedEndAt ?? .distantFuture, eb = b.estimatedEndAt ?? .distantFuture
                if ea != eb { return ea < eb }
            case 2:
                // Idle: recent finish first, never-finished last.
                switch (a.finishedAt, b.finishedAt) {
                case let (fa?, fb?) where fa != fb: return fa > fb
                case (.some, .none): return true
                case (.none, .some): return false
                default: break
                }
            default:
                break
            }
            let order = a.printerName.localizedCaseInsensitiveCompare(b.printerName)
            if order != .orderedSame { return order == .orderedAscending }
            return a.printerID < b.printerID
        }
    }
}
