import WidgetKit
import SwiftUI
import AppIntents
import NozzleCastShared

// Same fixed dark background as the AMS widget and the Live Activity Lock Screen.
private let statusWidgetBG = Color(hex: "#1a1a1a")

// MARK: - Printer entity for widget configuration

struct PrintStatusPrinterEntity: AppEntity {
    var id: String
    var printerName: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Printer" }
    static var defaultQuery: PrintStatusPrinterQuery { PrintStatusPrinterQuery() }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(printerName)")
    }
}

struct PrintStatusPrinterQuery: EntityQuery {
    func entities(for identifiers: [PrintStatusPrinterEntity.ID]) async throws -> [PrintStatusPrinterEntity] {
        PrintStatusWidgetStore.load()
            .filter { identifiers.contains($0.printerID) }
            .map { PrintStatusPrinterEntity(id: $0.printerID, printerName: $0.printerName) }
    }

    func suggestedEntities() async throws -> [PrintStatusPrinterEntity] {
        PrintStatusWidgetStore.load()
            .map { PrintStatusPrinterEntity(id: $0.printerID, printerName: $0.printerName) }
    }
}

// MARK: - Configuration intent

struct PrintStatusWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Print Status" }
    static var description: IntentDescription { IntentDescription("Choose which printer to show.") }

    @Parameter(title: "Printer", description: "Leave empty for Automatic, which shows the print that finishes soonest.")
    var printer: PrintStatusPrinterEntity?

    init() { self.printer = nil }
    init(printer: PrintStatusPrinterEntity?) { self.printer = printer }
}

// MARK: - Timeline entry & provider

struct PrintStatusEntry: TimelineEntry {
    let date: Date
    /// When the app last wrote the snapshot, which drives the staleness stamp.
    let capturedAt: Date?
    /// One for small and medium, up to two (picked first) for large. Empty means no data.
    let snapshots: [PrintStatusSnapshot]
    /// Pre-decoded covers keyed by `snapshot.printerID` so timeline entries share one decode.
    let covers: [String: CoverArt]

    init(
        date: Date,
        capturedAt: Date?,
        snapshots: [PrintStatusSnapshot],
        covers: [String: CoverArt] = [:]
    ) {
        self.date = date
        self.capturedAt = capturedAt
        self.snapshots = snapshots
        self.covers = covers
    }
}

struct PrintStatusProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PrintStatusEntry {
        PrintStatusEntry(date: .now, capturedAt: .now.addingTimeInterval(-120), snapshots: shown(Self.mockSnapshots(), for: context.family, printerID: nil))
    }

    func snapshot(for configuration: PrintStatusWidgetIntent, in context: Context) async -> PrintStatusEntry {
        let stored = PrintStatusWidgetStore.load()
        if stored.isEmpty {
            // Aged on purpose: a fresh stamp reads "0 sec ago".
            return PrintStatusEntry(date: .now, capturedAt: .now.addingTimeInterval(-120), snapshots: shown(Self.mockSnapshots(), for: context.family, printerID: nil))
        }
        let chosen = shown(stored, for: context.family, printerID: configuration.printer?.id)
        let covers = Self.preloadCovers(for: chosen, family: context.family)
        return PrintStatusEntry(date: .now, capturedAt: PrintStatusWidgetStore.lastSavedAt, snapshots: chosen, covers: covers)
    }

    func timeline(for configuration: PrintStatusWidgetIntent, in context: Context) async -> Timeline<PrintStatusEntry> {
        let now = Date.now
        let chosen = shown(PrintStatusWidgetStore.load(), for: context.family, printerID: configuration.printer?.id)
        let capturedAt = PrintStatusWidgetStore.lastSavedAt
        let covers = Self.preloadCovers(for: chosen, family: context.family)
        let hasActive = chosen.contains(where: \.isActive)

        let dates: [Date]
        let policy: TimelineReloadPolicy

        if context.family == .systemSmall {
            // Small doesn't render `StatusStamp`; only schedule entries for active countdown endings.
            if hasActive {
                let reload = now.addingTimeInterval(1800)
                var entryDates: Set<Date> = [now]
                entryDates.formUnion(chosen.compactMap(\.estimatedEndAt).filter { $0 > now && $0 < reload })
                dates = entryDates.sorted()
                policy = .after(reload)
            } else {
                dates = [now]
                policy = .never
            }
        } else if chosen.isEmpty {
            dates = [now]
            policy = .never
        } else if let capturedAt {
            let age = now.timeIntervalSince(capturedAt)
            if age < 3600 {
                // An entry a minute until the 60-minute mark or 30m reload, so the short "4m ago"
                // stamp counts up cleanly without exceeding a 30m reload window.
                let reload = now.addingTimeInterval(1800)
                let sixtyMinMark = capturedAt.addingTimeInterval(3600)
                let minuteTickLimit = min(reload, sixtyMinMark)
                var entryDates: Set<Date> = [now]
                for minuteOffset in 1..<30 {
                    let tick = now.addingTimeInterval(Double(minuteOffset) * 60)
                    guard tick < minuteTickLimit else { break }
                    entryDates.insert(tick)
                }
                if sixtyMinMark > now, sixtyMinMark < reload {
                    entryDates.insert(sixtyMinMark)
                }
                if hasActive {
                    entryDates.formUnion(chosen.compactMap(\.estimatedEndAt).filter { $0 > now && $0 < reload })
                }
                dates = entryDates.sorted()
                policy = .after(reload)
            } else {
                let reload = now.addingTimeInterval(3600)
                var entryDates: Set<Date> = [now]
                if hasActive {
                    entryDates.formUnion(chosen.compactMap(\.estimatedEndAt).filter { $0 > now && $0 < reload })
                }
                dates = entryDates.sorted()
                policy = .after(reload)
            }
        } else if hasActive {
            let reload = now.addingTimeInterval(1800)
            var entryDates: Set<Date> = [now]
            entryDates.formUnion(chosen.compactMap(\.estimatedEndAt).filter { $0 > now && $0 < reload })
            dates = entryDates.sorted()
            policy = .after(reload)
        } else {
            dates = [now]
            policy = .never
        }

        let entries = dates.map {
            PrintStatusEntry(date: $0, capturedAt: capturedAt, snapshots: chosen, covers: covers)
        }
        return Timeline(entries: entries, policy: policy)
    }

    private static func coverMaxPixelSize(for family: WidgetFamily) -> CGFloat {
        family == .systemSmall ? 168 : 288
    }

    private static func preloadCovers(for snapshots: [PrintStatusSnapshot], family: WidgetFamily) -> [String: CoverArt] {
        let maxPixelSize = coverMaxPixelSize(for: family)
        var covers: [String: CoverArt] = [:]
        covers.reserveCapacity(snapshots.count)
        for snapshot in snapshots {
            if let cover = coverArt(
                printerID: snapshot.printerID,
                jobName: snapshot.isActive ? snapshot.jobName : snapshot.lastJobName,
                maxPixelSize: maxPixelSize
            ) {
                covers[snapshot.printerID] = cover
            }
        }
        return covers
    }

    private func shown(_ all: [PrintStatusSnapshot], for family: WidgetFamily, printerID: String?) -> [PrintStatusSnapshot] {
        guard let first = PrintStatusSnapshot.pick(all, printerID: printerID) else { return [] }
        guard family == .systemLarge else { return [first] }
        let second = PrintStatusSnapshot.ranked(all).first { $0.printerID != first.printerID }
        return [first] + (second.map { [$0] } ?? [])
    }

    static func mockSnapshots() -> [PrintStatusSnapshot] {
        let now = Date.now
        return [
            PrintStatusSnapshot(
                printerID: "mock-studio-h2c",
                printerName: "Studio H2C",
                stateLabel: "Printing",
                isActive: true,
                progress: 0.64,
                jobName: "Honeycomb_Organizer.3mf",
                startedAt: now.addingTimeInterval(-2 * 3600),
                estimatedEndAt: now.addingTimeInterval(71 * 60),
                currentLayer: 140,
                totalLayers: 226,
                nozzleTempC: 220,
                rightNozzleTempC: 150,
                bedTempC: 60
            ),
            PrintStatusSnapshot(
                printerID: "mock-workshop-x1c",
                printerName: "Workshop X1C",
                stateLabel: "Printing",
                isActive: true,
                progress: 0.22,
                jobName: "Gridfinity_Bin_2x3.3mf",
                startedAt: now.addingTimeInterval(-30 * 60),
                estimatedEndAt: now.addingTimeInterval(108 * 60),
                currentLayer: 56,
                totalLayers: 248,
                nozzleTempC: 220,
                bedTempC: 60
            ),
        ]
    }
}

// MARK: - Mapping

private extension PrintStatusSnapshot {
    /// Lets the Live Activity's shared components render a snapshot unchanged.
    var contentState: PrintActivityAttributes.ContentState {
        PrintActivityAttributes.ContentState(
            progress: progress,
            stateLabel: stateLabel,
            jobName: jobName,
            startedAt: startedAt,
            estimatedEndAt: estimatedEndAt,
            currentLayer: currentLayer,
            totalLayers: totalLayers,
            nozzleTempC: nozzleTempC,
            rightNozzleTempC: rightNozzleTempC,
            bedTempC: bedTempC,
            coverImage: nil,
            issueSeverity: issueSeverity,
            issueCount: issueCount,
            // Never the stage ("Homing toolhead"): the widget refreshes rarely, so a stage that
            // lasts seconds stayed on it for an hour. The job name doesn't go stale.
            stageDetail: nil
        )
    }

    var deepLink: URL? { URL(string: "nozzlecast://printer/\(printerID)") }
}

// MARK: - Shared pieces

/// The cover in full colour. A widget only redraws when the app refreshes, so the Live Activity's
/// build-up fill, % and segments would sit frozen at an old percentage here; the countdown, which
/// ticks on its own, carries the progress instead.
private func statusCover(_ snapshot: PrintStatusSnapshot, cover: CoverArt?, width: CGFloat, height: CGFloat, cornerRadius: CGFloat) -> some View {
    BuildUpThumbnail(
        cover: cover, fraction: 1,
        width: width, height: height, cornerRadius: cornerRadius, showsBuildUp: false
    )
    .overlay(alignment: .topTrailing) {
        issueBadge(snapshot.contentState).padding(-3)
    }
}

private struct FinishedText: View {
    let snapshot: PrintStatusSnapshot
    let size: CGFloat

    var body: some View {
        Group {
            // Worded by how the last print ended: a failed or cancelled print didn't "finish", and
            // an outcome the app couldn't read gets the neutral wording.
            if let finishedAt = snapshot.finishedAt {
                switch snapshot.lastOutcome {
                case .completed: Text("Finished \(finishedAt, style: .relative) ago")
                case .failed: Text("Failed \(finishedAt, style: .relative) ago")
                case .cancelled: Text("Cancelled \(finishedAt, style: .relative) ago")
                case nil: Text("Last print \(finishedAt, style: .relative) ago")
                }
            } else {
                Text("Idle")
            }
        }
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// The Lock Screen card: thumbnail left, details right. `detailed` adds the temperature chips and
/// staleness stamp (medium); large drops them and uses the taller thumbnail.
private struct StatusCard: View {
    let snapshot: PrintStatusSnapshot
    let cover: CoverArt?
    let capturedAt: Date?
    let now: Date
    let thumbHeight: CGFloat
    let detailed: Bool

    /// Medium only: a dual-nozzle print's three temperature chips fill the row the stamp shares.
    private var stampBesideName: Bool {
        detailed && snapshot.isActive && snapshot.nozzleTempC != nil && snapshot.rightNozzleTempC != nil
    }

    var body: some View {
        let state = snapshot.contentState
        HStack(alignment: .top, spacing: 14) {
            SafeSection {
                statusCover(snapshot, cover: cover, width: 96, height: thumbHeight, cornerRadius: 16)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(snapshot.printerName)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if stampBesideName {
                        Spacer(minLength: 0)
                        StatusStamp(capturedAt: capturedAt, now: now)
                    }
                }
                if snapshot.isActive {
                    SafeSection { JobSubtitle(state: state, font: .caption) }
                    SafeSection {
                        Countdown(state: state, referenceDate: now)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    SafeSection {
                        HStack {
                            if let end = state.estimatedEndAt {
                                HStack(spacing: 3) {
                                    Image(systemName: "stopwatch")
                                    Text(end, style: .time)
                                }
                            }
                            // No layer count: like the %, it only moves when the app refreshes.
                            Spacer()
                        }
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                    }
                    if detailed {
                        SafeSection {
                            HStack(spacing: 6) {
                                // Chips never compress. A dual-nozzle printer's three chips leave
                                // ~20pt, which cut the stamp to "32m a…", so there it sits beside
                                // the name instead (see `stampBesideName`).
                                temperatureChips(state).fixedSize()
                                Spacer(minLength: 0)
                                if !stampBesideName {
                                    StatusStamp(capturedAt: capturedAt, now: now)
                                }
                            }
                        }
                    }
                } else {
                    if let last = snapshot.lastJobName {
                        Text(last)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    FinishedText(snapshot: snapshot, size: 20)
                    if detailed {
                        Spacer(minLength: 0)
                        StatusStamp(capturedAt: capturedAt, now: now)
                    }
                }
            }
        }
    }
}

@MainActor
private enum SnapshotAgeFormatter {
    static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

/// "4m ago": how old the snapshot is at the entry's date. Static text, kept current by the
/// timeline's per-minute entries.
@MainActor
private func snapshotAge(_ capturedAt: Date, at now: Date) -> String {
    // Under a minute reads "in 0 sec"/"0 sec ago" otherwise.
    SnapshotAgeFormatter.relative.localizedString(for: min(capturedAt, now.addingTimeInterval(-60)), relativeTo: now)
}

private struct StatusStamp: View {
    let capturedAt: Date?
    let now: Date

    var body: some View {
        if let capturedAt {
            Text(snapshotAge(capturedAt, at: now))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
                // Short text ("32m ago"): never shrunk or cut; the layout makes room for it.
                .fixedSize()
        }
    }
}

// MARK: - Small

private struct PrintStatusSmallView: View {
    let snapshot: PrintStatusSnapshot
    let cover: CoverArt?
    let now: Date

    var body: some View {
        let state = snapshot.contentState
        VStack(alignment: .leading, spacing: 6) {
            SafeSection {
                statusCover(snapshot, cover: cover, width: 56, height: 72, cornerRadius: 12)
            }
            Spacer(minLength: 0)
            Text(snapshot.printerName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if snapshot.isActive {
                SafeSection {
                    Countdown(state: state, referenceDate: now)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                }
            } else {
                FinishedText(snapshot: snapshot, size: 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Medium

private struct PrintStatusMediumView: View {
    let snapshot: PrintStatusSnapshot
    let cover: CoverArt?
    let capturedAt: Date?
    let now: Date

    var body: some View {
        // The thumbnail takes the full content height, which varies by device (the medium widget is
        // 170pt on most iPhones but shorter on the smallest), so it's measured, not fixed.
        GeometryReader { proxy in
            StatusCard(snapshot: snapshot, cover: cover, capturedAt: capturedAt, now: now, thumbHeight: proxy.size.height, detailed: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Large

private struct PrintStatusLargeView: View {
    let snapshots: [PrintStatusSnapshot]
    let covers: [String: CoverArt]
    let capturedAt: Date?
    let now: Date

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(snapshots.prefix(2).enumerated()), id: \.element.printerID) { index, snapshot in
                if index > 0 {
                    Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
                        .padding(.vertical, 10)
                }
                Link(destination: snapshot.deepLink ?? URL(string: "nozzlecast://monitor")!) {
                    StatusCard(snapshot: snapshot, cover: covers[snapshot.printerID], capturedAt: capturedAt, now: now, thumbHeight: 128, detailed: false)
                }
            }
            Spacer(minLength: 0)
            if let capturedAt {
                HStack {
                    Spacer()
                    Text("Updated \(snapshotAge(capturedAt, at: now))")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Entry view

struct PrintStatusWidgetEntryView: View {
    var entry: PrintStatusEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let first = entry.snapshots.first {
                switch family {
                case .systemSmall:
                    PrintStatusSmallView(snapshot: first, cover: entry.covers[first.printerID], now: entry.date)
                        .widgetURL(first.deepLink)
                case .systemLarge:
                    PrintStatusLargeView(snapshots: entry.snapshots, covers: entry.covers, capturedAt: entry.capturedAt, now: entry.date)
                default:
                    PrintStatusMediumView(snapshot: first, cover: entry.covers[first.printerID], capturedAt: entry.capturedAt, now: entry.date)
                        .widgetURL(first.deepLink)
                }
            } else {
                emptyState
            }
        }
        .containerBackground(statusWidgetBG, for: .widget)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "printer")
                .font(.title2)
                .foregroundStyle(Color.white.opacity(0.3))
            Text("Open NozzleCast to see your printers")
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.white.opacity(0.75))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Widget

struct PrintStatusWidget: Widget {
    let kind = "PrintStatusWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: PrintStatusWidgetIntent.self, provider: PrintStatusProvider()) { entry in
            PrintStatusWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Print Status")
        .description("Your print's progress and time left, like the Live Activity.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Previews

#Preview("Print Status – Small", as: .systemSmall) {
    PrintStatusWidget()
} timeline: {
    PrintStatusEntry(date: .now, capturedAt: .now.addingTimeInterval(-240), snapshots: [PrintStatusProvider.mockSnapshots()[0]])
}

#Preview("Print Status – Medium", as: .systemMedium) {
    PrintStatusWidget()
} timeline: {
    PrintStatusEntry(date: .now, capturedAt: .now.addingTimeInterval(-240), snapshots: [PrintStatusProvider.mockSnapshots()[0]])
}

#Preview("Print Status – Large", as: .systemLarge) {
    PrintStatusWidget()
} timeline: {
    PrintStatusEntry(date: .now, capturedAt: .now.addingTimeInterval(-240), snapshots: PrintStatusProvider.mockSnapshots())
}

#Preview("Print Status – Paused", as: .systemMedium) {
    PrintStatusWidget()
} timeline: {
    PrintStatusEntry(date: .now, capturedAt: .now.addingTimeInterval(-240), snapshots: [pausedPrintStatusPreviewSnapshot()])
}

#Preview("Print Status – Idle", as: .systemMedium) {
    PrintStatusWidget()
} timeline: {
    PrintStatusEntry(date: .now, capturedAt: .now.addingTimeInterval(-240), snapshots: [idlePrintStatusPreviewSnapshot()])
}

#Preview("Print Status – Large, one printer", as: .systemLarge) {
    PrintStatusWidget()
} timeline: {
    PrintStatusEntry(date: .now, capturedAt: .now.addingTimeInterval(-240), snapshots: [PrintStatusProvider.mockSnapshots()[0]])
}

#Preview("Print Status – Empty", as: .systemSmall) {
    PrintStatusWidget()
} timeline: {
    PrintStatusEntry(date: .now, capturedAt: nil, snapshots: [])
}

/// The first mock printer, paused with a warning. A copy, so the mock itself is untouched.
private func pausedPrintStatusPreviewSnapshot() -> PrintStatusSnapshot {
    var snapshot = PrintStatusProvider.mockSnapshots()[0]
    snapshot.stateLabel = "Paused"
    snapshot.issueSeverity = "warning"
    snapshot.issueCount = 1
    return snapshot
}

/// A printer that finished its last print 25 minutes ago and has nothing loaded.
private func idlePrintStatusPreviewSnapshot() -> PrintStatusSnapshot {
    PrintStatusSnapshot(
        printerID: "mock-studio-h2c",
        printerName: "Studio H2C",
        stateLabel: "Idle",
        isActive: false,
        lastJobName: "Honeycomb_Organizer.3mf",
        finishedAt: .now.addingTimeInterval(-25 * 60),
        lastOutcome: .completed
    )
}
