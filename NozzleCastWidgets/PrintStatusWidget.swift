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
        return PrintStatusEntry(date: .now, capturedAt: PrintStatusWidgetStore.lastSavedAt, snapshots: shown(stored, for: context.family, printerID: configuration.printer?.id))
    }

    func timeline(for configuration: PrintStatusWidgetIntent, in context: Context) async -> Timeline<PrintStatusEntry> {
        let now = Date.now
        let chosen = shown(PrintStatusWidgetStore.load(), for: context.family, printerID: configuration.printer?.id)
        let capturedAt = PrintStatusWidgetStore.lastSavedAt

        let reload = now.addingTimeInterval(1800)
        // An entry a minute until the next reload, so the short "4m ago" stamp counts up (a live
        // relative date reads "1 min, 36 sec ago", too wide beside the chips). Entries within one
        // timeline don't cost reload budget. Plus one when each shown print's estimate passes, so
        // the countdown gives way to the state label.
        var dates = Set((0..<30).map { now.addingTimeInterval(Double($0) * 60) })
        dates.formUnion(chosen.compactMap(\.estimatedEndAt).filter { $0 > now && $0 < reload })
        let entries = dates.sorted().map { PrintStatusEntry(date: $0, capturedAt: capturedAt, snapshots: chosen) }
        return Timeline(entries: entries, policy: .after(reload))
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
            stageDetail: stageDetail
        )
    }

    var cover: CoverArt? {
        coverArt(printerID: printerID, jobName: isActive ? jobName : lastJobName)
    }

    var deepLink: URL? { URL(string: "nozzlecast://printer/\(printerID)") }
}

// MARK: - Shared pieces

private struct PercentCapsule: View {
    let state: PrintActivityAttributes.ContentState

    var body: some View {
        LiveProgressText(state: state)
            .font(.caption)
            .foregroundStyle(accentLight)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(accent.opacity(0.2)))
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
    let capturedAt: Date?
    let now: Date
    let thumbHeight: CGFloat
    let detailed: Bool

    var body: some View {
        let state = snapshot.contentState
        HStack(alignment: .top, spacing: 14) {
            SafeSection {
                BuildUpThumbnail(
                    cover: snapshot.cover,
                    fraction: snapshot.isActive ? buildFraction(state) : 1,
                    width: 96, height: thumbHeight, cornerRadius: 16
                )
                .overlay(alignment: .topTrailing) {
                    issueBadge(state).padding(-3)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                SafeSection {
                    HStack {
                        Text(snapshot.printerName)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer()
                        if snapshot.isActive {
                            PercentCapsule(state: state)
                        }
                    }
                }
                if snapshot.isActive {
                    SafeSection { JobSubtitle(state: state, font: .caption) }
                    SafeSection {
                        Countdown(state: state)
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
                            Spacer()
                            layerCounter(state)
                        }
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                    }
                    SafeSection {
                        SegmentedProgress(progress: state.progress, height: 7, spacing: 2)
                    }
                    if detailed {
                        SafeSection {
                            HStack(spacing: 6) {
                                // Chips never compress; the stamp gives way first.
                                temperatureChips(state).fixedSize()
                                Spacer(minLength: 0)
                                StatusStamp(capturedAt: capturedAt, now: now)
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

/// "4m ago": how old the snapshot is at the entry's date. Static text, kept current by the
/// timeline's per-minute entries.
private func snapshotAge(_ capturedAt: Date, at now: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    // Under a minute reads "in 0 sec"/"0 sec ago" otherwise.
    return formatter.localizedString(for: min(capturedAt, now.addingTimeInterval(-60)), relativeTo: now)
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
                .minimumScaleFactor(0.7)
        }
    }
}

// MARK: - Small

private struct PrintStatusSmallView: View {
    let snapshot: PrintStatusSnapshot

    var body: some View {
        let state = snapshot.contentState
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                SafeSection {
                    BuildUpThumbnail(
                        cover: snapshot.cover,
                        fraction: snapshot.isActive ? buildFraction(state) : 1,
                        width: 56, height: 72, cornerRadius: 12
                    )
                    .overlay(alignment: .topTrailing) {
                        issueBadge(state).padding(-3)
                    }
                }
                Spacer(minLength: 0)
                if snapshot.isActive {
                    PercentCapsule(state: state)
                }
            }
            Text(snapshot.printerName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if snapshot.isActive {
                SafeSection {
                    Countdown(state: state)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                }
                SafeSection {
                    SegmentedProgress(progress: state.progress, height: 6, spacing: 2)
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
    let capturedAt: Date?
    let now: Date

    var body: some View {
        // The thumbnail takes the full content height, which varies by device (the medium widget is
        // 170pt on most iPhones but shorter on the smallest), so it's measured, not fixed.
        GeometryReader { proxy in
            StatusCard(snapshot: snapshot, capturedAt: capturedAt, now: now, thumbHeight: proxy.size.height, detailed: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Large

private struct PrintStatusLargeView: View {
    let snapshots: [PrintStatusSnapshot]
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
                    StatusCard(snapshot: snapshot, capturedAt: capturedAt, now: now, thumbHeight: 128, detailed: false)
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
                    PrintStatusSmallView(snapshot: first)
                        .widgetURL(first.deepLink)
                case .systemLarge:
                    PrintStatusLargeView(snapshots: entry.snapshots, capturedAt: entry.capturedAt, now: entry.date)
                default:
                    PrintStatusMediumView(snapshot: first, capturedAt: entry.capturedAt, now: entry.date)
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
