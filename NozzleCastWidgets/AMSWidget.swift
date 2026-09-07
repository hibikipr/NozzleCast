import WidgetKit
import SwiftUI
import AppIntents
import NozzleCastShared

private let widgetBG = Color(red: 0x1a / 255, green: 0x1a / 255, blue: 0x1a / 255)
private let deepLink = URL(string: "nozzlecast://monitor")!

// MARK: - Printer entity for widget configuration

struct PrinterEntity: AppEntity {
    var id: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Printer" }
    static var defaultQuery: PrinterEntityQuery { PrinterEntityQuery() }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)")
    }
}

struct PrinterEntityQuery: EntityQuery {
    func entities(for identifiers: [PrinterEntity.ID]) async throws -> [PrinterEntity] {
        let stored = AMSWidgetStore.load()
        return stored.filter { identifiers.contains($0.printerName) }.map { PrinterEntity(id: $0.printerName) }
    }

    func suggestedEntities() async throws -> [PrinterEntity] {
        AMSWidgetStore.load().map { PrinterEntity(id: $0.printerName) }
    }
}

// MARK: - Widget configuration intent

struct AMSWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "AMS Colors" }
    static var description: IntentDescription { IntentDescription("Choose which printers to show.") }

    /// Nil or empty = show all printers (the default).
    @Parameter(title: "Printers", description: "Leave empty to show all printers.")
    var printers: [PrinterEntity]?

    init() { self.printers = nil }
    init(printers: [PrinterEntity]?) { self.printers = printers }
}

// MARK: - Timeline entry & provider

struct AMSEntry: TimelineEntry {
    let date: Date
    let printers: [PrinterAMSSnapshot]
}

struct AMSProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> AMSEntry {
        AMSEntry(date: .now, printers: Self.mockPrinters())
    }

    func snapshot(for configuration: AMSWidgetIntent, in context: Context) async -> AMSEntry {
        let stored = filtered(AMSWidgetStore.load(), by: configuration)
        return AMSEntry(date: .now, printers: stored.isEmpty ? Self.mockPrinters() : stored)
    }

    func timeline(for configuration: AMSWidgetIntent, in context: Context) async -> Timeline<AMSEntry> {
        let printers = filtered(AMSWidgetStore.load(), by: configuration)
        let entry = AMSEntry(date: .now, printers: printers)
        return Timeline(entries: [entry], policy: .after(.now.advanced(by: 1800)))
    }

    private func filtered(_ all: [PrinterAMSSnapshot], by intent: AMSWidgetIntent) -> [PrinterAMSSnapshot] {
        let selected = Set((intent.printers ?? []).map(\.id))
        guard !selected.isEmpty else { return all }
        return all.filter { selected.contains($0.printerName) }
    }

    static func mockPrinters() -> [PrinterAMSSnapshot] {
        [
            PrinterAMSSnapshot(
                printerName: "Workshop X1C",
                stateLabel: "Printing",
                isPrinting: true,
                amsUnits: [
                    AMSUnitSnapshot(displayName: "AMS 1", trays: [
                        AMSTraySnapshot(colorHex: "#E8622C", materialLabel: "PLA"),
                        AMSTraySnapshot(colorHex: "#D9E4E8", colorAlpha: 0.18, effectType: "translucent", materialLabel: "PETG"),
                        AMSTraySnapshot(colorHex: "#E8622C", extraColorHexes: ["#D9A426", "#2A5FCC", "#C22A7A"], subtype: "Multicolor", effectType: "multicolor", materialLabel: "PLA"),
                        AMSTraySnapshot(colorHex: "#141414", effectType: "sparkle", materialLabel: "PLA"),
                    ])
                ]
            ),
            PrinterAMSSnapshot(
                printerName: "Office P1S",
                stateLabel: "Paused",
                isPrinting: false,
                amsUnits: [
                    AMSUnitSnapshot(displayName: "AMS 1", trays: [
                        AMSTraySnapshot(colorHex: nil, materialLabel: nil),
                        AMSTraySnapshot(colorHex: nil, materialLabel: nil),
                        AMSTraySnapshot(colorHex: "#F2F2F2", materialLabel: "ABS"),
                        AMSTraySnapshot(colorHex: nil, materialLabel: nil),
                    ])
                ]
            ),
        ]
    }
}

// MARK: - Tray dot (circle — matches monitoring screen, full swatch rendering)

private struct TrayDot: View {
    var tray: AMSTraySnapshot
    var size: CGFloat

    var body: some View {
        if let hex = tray.colorHex {
            FilamentSwatchView(
                colorHex: hex,
                alpha: tray.colorAlpha,
                extraColorHexes: tray.extraColorHexes,
                subtype: tray.subtype,
                effectType: tray.effectType
            )
            .clipShape(Circle())
            .frame(width: size, height: size)
        } else {
            Circle()
                .fill(Color.white.opacity(0.08))
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Per-printer section (shared between small and medium)

private struct PrinterSection: View {
    let printer: PrinterAMSSnapshot
    let dotSize: CGFloat
    let dotSpacing: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                if printer.isPrinting {
                    Circle()
                        .fill(Color(hex: "#22C55E"))
                        .frame(width: 6, height: 6)
                }
                Text(printer.printerName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("· \(printer.stateLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            ForEach(Array(printer.amsUnits.enumerated()), id: \.offset) { _, unit in
                VStack(alignment: .leading, spacing: 3) {
                    if printer.amsUnits.count > 1 {
                        Text(unit.displayName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.35))
                    }
                    HStack(spacing: dotSpacing) {
                        ForEach(Array(unit.trays.prefix(4).enumerated()), id: \.offset) { _, tray in
                            TrayDot(tray: tray, size: dotSize)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Small layout (first printing printer, or first)

private struct AMSSmallView: View {
    let printer: PrinterAMSSnapshot

    var body: some View {
        PrinterSection(printer: printer, dotSize: 15, dotSpacing: 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Medium layout (two-column when ≥2 printers)

private struct AMSMediumView: View {
    let printers: [PrinterAMSSnapshot]

    private var leftCount: Int { (printers.count + 1) / 2 }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            printerColumn(Array(printers.prefix(leftCount)))

            if printers.count > 1 {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1)
                    .padding(.horizontal, 10)

                printerColumn(Array(printers.dropFirst(leftCount)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func printerColumn(_ items: [PrinterAMSSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, printer in
                PrinterSection(printer: printer, dotSize: 15, dotSpacing: 6)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Entry view

struct AMSWidgetEntryView: View {
    var entry: AMSEntry
    @Environment(\.widgetFamily) private var family

    private var leadPrinter: PrinterAMSSnapshot? {
        entry.printers.first(where: \.isPrinting) ?? entry.printers.first
    }

    var body: some View {
        Group {
            if family == .systemSmall {
                if let printer = leadPrinter {
                    AMSSmallView(printer: printer)
                } else {
                    emptyState
                }
            } else {
                if !entry.printers.isEmpty {
                    AMSMediumView(printers: entry.printers)
                } else {
                    emptyState
                }
            }
        }
        .containerBackground(widgetBG, for: .widget)
        .widgetURL(deepLink)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "printer")
                .font(.largeTitle)
                .foregroundStyle(Color.white.opacity(0.25))
            Text("No printers")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Widget

struct AMSWidget: Widget {
    let kind = "AMSWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: AMSWidgetIntent.self, provider: AMSProvider()) { entry in
            AMSWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("AMS Colors")
        .description("Shows the filament colors loaded in each AMS unit.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Color helper

private extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        s.removeAll { $0 == "#" }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

// MARK: - Previews

#Preview("AMS – Small", as: .systemSmall) {
    AMSWidget()
} timeline: {
    AMSEntry(date: .now, printers: AMSProvider.mockPrinters())
}

#Preview("AMS – Medium", as: .systemMedium) {
    AMSWidget()
} timeline: {
    AMSEntry(date: .now, printers: AMSProvider.mockPrinters())
}
