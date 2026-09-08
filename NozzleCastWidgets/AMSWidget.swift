import WidgetKit
import SwiftUI
import AppIntents
import NozzleCastShared

// Fixed, not adaptive: NozzleCast forces `.preferredColorScheme(.dark)` everywhere in the app
// (see RootView.swift) and NCColor has no light-mode variants. WidgetKit gives widgets no way
// to force their own color scheme, so the container background is pinned dark here and paired
// with fixed light-on-dark foreground tones, matching how the rest of the app stays single-theme
// rather than mixing in a light appearance nothing else in the product supports.
private let widgetBG = Color(red: 0x1a / 255, green: 0x1a / 255, blue: 0x1a / 255)
private let accentBlue = Color(red: 0x2A / 255, green: 0x5F / 255, blue: 0xCC / 255)
private let statusPrinting = Color(red: 0x22 / 255, green: 0xC5 / 255, blue: 0x5E / 255)
private let statusPaused = Color(red: 0xF5 / 255, green: 0x9E / 255, blue: 0x0B / 255)
private let deepLink = URL(string: "nozzlecast://monitor")!

/// A widget canvas is fixed, so content is bounded by design, never clipped by WidgetKit.
private let maxUnitsPerPrinter = 3   // 2× AMS2 Pro + 1× AMS HT = 9 slots, the real fleet's ceiling
private let maxPrintersShown = 2     // Medium's two columns; Large mirrors it so a third printer
                                      // (each with up to 3 multi-slot units) can't push it past 382pt

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

// MARK: - Configuration & refresh intents

struct AMSWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "AMS Colors" }
    static var description: IntentDescription { IntentDescription("Choose which printers to show.") }

    /// Nil or empty = show all printers (the default).
    @Parameter(title: "Printers", description: "Leave empty to show all printers.")
    var printers: [PrinterEntity]?

    init() { self.printers = nil }
    init(printers: [PrinterEntity]?) { self.printers = printers }
}

/// iOS 17+ in-widget refresh — widgets get no gestures, so this is a Button, not a pull.
struct RefreshAMSIntent: AppIntent {
    static var title: LocalizedStringResource { "Refresh AMS" }
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadTimelines(ofKind: "AMSWidget")
        return .result()
    }
}

// MARK: - Timeline entry & provider

struct AMSEntry: TimelineEntry {
    let date: Date
    /// When the app last wrote the snapshot — drives the staleness stamp.
    let capturedAt: Date?
    let printers: [PrinterAMSSnapshot]

    init(date: Date, capturedAt: Date? = nil, printers: [PrinterAMSSnapshot]) {
        self.date = date
        self.capturedAt = capturedAt
        self.printers = printers
    }
}

struct AMSProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> AMSEntry {
        AMSEntry(date: .now, capturedAt: .now, printers: Self.mockPrinters())
    }

    func snapshot(for configuration: AMSWidgetIntent, in context: Context) async -> AMSEntry {
        let stored = filtered(AMSWidgetStore.load(), by: configuration)
        return AMSEntry(date: .now, capturedAt: .now, printers: stored.isEmpty ? Self.mockPrinters() : stored)
    }

    func timeline(for configuration: AMSWidgetIntent, in context: Context) async -> Timeline<AMSEntry> {
        let printers = filtered(AMSWidgetStore.load(), by: configuration)
        let entry = AMSEntry(date: .now, capturedAt: AMSWidgetStore.lastSavedAt, printers: printers)
        // One entry, 30 min out (~48 reloads/day) — inside WidgetKit's budget.
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
                printerName: "Garage H2C",
                stateLabel: "Printing",
                isPrinting: true,
                amsUnits: [
                    AMSUnitSnapshot(displayName: "AMS 1", isHighTemp: false, trays: [
                        AMSTraySnapshot(colorHex: "#E8622C", materialLabel: "PLA"),
                        AMSTraySnapshot(colorHex: "#D9E4E8", colorAlpha: 0.18, effectType: "translucent", materialLabel: "PETG"),
                        AMSTraySnapshot(colorHex: "#E8622C", extraColorHexes: ["#D9A426", "#2A5FCC", "#C22A7A"], subtype: "Multicolor", effectType: "multicolor", materialLabel: "PLA"),
                        AMSTraySnapshot(colorHex: "#141414", effectType: "sparkle", materialLabel: "PLA"),
                    ]),
                    AMSUnitSnapshot(displayName: "AMS 2", isHighTemp: false, trays: [
                        AMSTraySnapshot(colorHex: "#2A5FCC", materialLabel: "PLA"),
                        // The worst case for this row deliberately: the longest real material
                        // name Bambu reports, on the lightest swatch. Exercises both the label
                        // shortening and the light-swatch contrast tone in every preview.
                        AMSTraySnapshot(colorHex: "#F2F2F2", materialLabel: "Support for PLA"),
                        AMSTraySnapshot(colorHex: nil, materialLabel: nil),
                        AMSTraySnapshot(colorHex: "#22C55E", materialLabel: "PLA"),
                    ]),
                    AMSUnitSnapshot(displayName: "AMS-HT", isHighTemp: true, trays: [
                        AMSTraySnapshot(colorHex: "#3A3A3A", materialLabel: "PAHT-CF"),
                    ]),
                ]
            ),
            PrinterAMSSnapshot(
                printerName: "Office P1S",
                stateLabel: "Paused",
                isPrinting: false,
                amsUnits: [
                    AMSUnitSnapshot(displayName: "AMS 1", isHighTemp: false, trays: [
                        AMSTraySnapshot(colorHex: "#C22A7A", materialLabel: "PLA"),
                        AMSTraySnapshot(colorHex: "#D9A426", materialLabel: "PLA"),
                        AMSTraySnapshot(colorHex: nil, materialLabel: nil),
                        AMSTraySnapshot(colorHex: "#F2F2F2", materialLabel: "ABS"),
                    ]),
                    AMSUnitSnapshot(displayName: "AMS-HT", isHighTemp: true, trays: [
                        AMSTraySnapshot(colorHex: "#6E6E6E", materialLabel: "PC"),
                    ]),
                ]
            ),
        ]
    }
}

// MARK: - Tray swatch (rounded rect — matches the app's spool swatches, not a dot)

private struct TraySwatch: View {
    var tray: AMSTraySnapshot
    var accessibilityPrefix: String
    var size: CGFloat
    var corner: CGFloat
    var showsMaterialLabel: Bool = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: corner, style: .continuous) }

    /// Derived from the swatch rather than fixed. This was a hardcoded 6.5pt shared by medium and
    /// large, but the large swatch has roughly twice the area of the medium one -- same absolute
    /// label, half the relative size, which is exactly why large read as too small while medium
    /// looked fine.
    private var labelFontSize: CGFloat { max(7, size * 0.30) }

    private var foreground: SwatchForeground {
        SwatchContrast.preferredForeground(
            colorHex: tray.colorHex,
            alpha: tray.colorAlpha,
            extraColorHexes: tray.extraColorHexes
        )
    }

    /// Not pure black: full black on a mid-tone pill reads harsher than the swatch deserves, and
    /// 0.85 still clears the contrast the tone was chosen for.
    private var labelTone: Color { foreground == .dark ? Color.black.opacity(0.85) : .white }

    /// A swatch can be a gradient, a multi-colour blend, or the support filament's checkerboard --
    /// patterns with both light and dark regions, where no single text colour works everywhere.
    /// A 1pt shadow in the opposite tone holds the text over those without reintroducing a band:
    /// on a flat colour it is invisible.
    private var labelShadowTone: Color { foreground == .dark ? .white : .black }

    var body: some View {
        Group {
            if let hex = tray.colorHex {
                FilamentSwatchView(
                    colorHex: hex,
                    alpha: tray.colorAlpha,
                    extraColorHexes: tray.extraColorHexes,
                    subtype: tray.subtype,
                    effectType: tray.effectType
                )
                // Centred on the pill with no backing band. The band used to hide the bottom
                // quarter of a swatch whose colour is the entire point of this widget -- and on a
                // black swatch, white over 45%-black over black was barely legible anyway. The
                // tone is derived from the swatch instead, so the label sits on the colour with
                // nothing between them.
                .overlay {
                    if showsMaterialLabel, let material = MaterialLabel.short(tray.materialLabel) {
                        Text(material)
                            .font(.system(size: labelFontSize, weight: .bold))
                            .lineLimit(1)
                            // Was 0.6, which let "Support for PLA" shrink to ~3.9pt -- rendering
                            // the one label in the row carrying real information as the smallest
                            // text on screen. A long name now truncates instead of dissolving.
                            .minimumScaleFactor(0.85)
                            .foregroundStyle(labelTone)
                            .shadow(color: labelShadowTone.opacity(0.5), radius: 1)
                            .padding(.horizontal, 2)
                    }
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            } else {
                shape
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        shape.strokeBorder(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    )
            }
        }
        .frame(height: size)
        .accessibilityElement(children: .ignore)
        // Deliberately the unshortened name: "Support for PLA" is clearer spoken than "PLA SUP".
        // The shortening exists to fit a ~28-65pt box, a constraint VoiceOver does not have.
        .accessibilityLabel("\(accessibilityPrefix), \(tray.materialLabel ?? "empty")")
    }
}

// MARK: - One AMS unit = one row (unit is the row, slot is the column)

private struct UnitRow: View {
    let unit: AMSUnitSnapshot
    let shortTag: String
    let longTag: String
    let tagWidth: CGFloat
    let useLongTag: Bool
    let swatchSize: CGFloat
    let corner: CGFloat
    /// Extra trailing detail for single-slot (HT) rows, where there's leftover row width.
    let showsHTDetail: Bool
    var showsMaterialLabel: Bool = false

    private var trays: [AMSTraySnapshot] { Array(unit.trays.prefix(4)) }

    var body: some View {
        HStack(spacing: 7) {
            Text(useLongTag ? longTag : shortTag)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.4)
                .textCase(.uppercase)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(unit.isHighTemp ? statusPaused : Color.white.opacity(0.4))
                .frame(width: tagWidth, alignment: .leading)

            if trays.count == 1 {
                // AMS HT: keep the swatch the same size as the others and spend the leftover
                // row width on the material name instead of stretching it into a fake AMS.
                TraySwatch(tray: trays[0], accessibilityPrefix: "\(longTag) slot 1", size: swatchSize, corner: corner)
                    .frame(width: swatchSize)
                if showsHTDetail, let material = MaterialLabel.short(trays[0].materialLabel) {
                    Text(material)
                        .font(.caption2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(Color.white.opacity(0.55))
                }
                Spacer(minLength: 0)
            } else {
                HStack(spacing: 5) {
                    ForEach(Array(trays.enumerated()), id: \.offset) { index, tray in
                        TraySwatch(
                            tray: tray,
                            accessibilityPrefix: "\(shortTag) slot \(index + 1)",
                            size: swatchSize,
                            corner: corner,
                            showsMaterialLabel: showsMaterialLabel
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

// MARK: - Shared bits

private struct PrinterHeader: View {
    let printer: PrinterAMSSnapshot
    var trailing: String?

    private var dotColor: Color {
        if printer.isPrinting { return statusPrinting }
        if printer.stateLabel.localizedCaseInsensitiveContains("pause") { return statusPaused }
        return Color.white.opacity(0.3)
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(dotColor).frame(width: 7, height: 7)
            Text(printer.printerName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(.caption2)
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(Color.white.opacity(0.45))
            }
        }
    }
}

private struct PrinterUnits: View {
    let printer: PrinterAMSSnapshot
    let swatchSize: CGFloat
    let corner: CGFloat
    let tagWidth: CGFloat
    let useLongTag: Bool
    let rowSpacing: CGFloat
    var showsHTDetail = true
    var showsMaterialLabel = false

    private var units: [AMSUnitSnapshot] { Array(printer.amsUnits.prefix(maxUnitsPerPrinter)) }
    private var hiddenUnits: Int { max(0, printer.amsUnits.count - maxUnitsPerPrinter) }

    var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(Array(units.enumerated()), id: \.offset) { index, unit in
                UnitRow(
                    unit: unit,
                    shortTag: unit.isHighTemp ? "HT" : "A\(regularUnitNumber(upTo: index))",
                    longTag: unit.displayName,
                    tagWidth: tagWidth,
                    useLongTag: useLongTag,
                    swatchSize: swatchSize,
                    corner: corner,
                    showsHTDetail: showsHTDetail,
                    showsMaterialLabel: showsMaterialLabel
                )
            }
            if hiddenUnits > 0 {
                Text("+\(hiddenUnits) AMS")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.4))
            }
        }
    }

    /// Numbering ignores HT units, so a multi-AMS printer reads A1 / A2 / HT.
    private func regularUnitNumber(upTo index: Int) -> Int {
        units.prefix(index + 1).filter { !$0.isHighTemp }.count
    }
}

private struct StaleStamp: View {
    let capturedAt: Date?

    var body: some View {
        Group {
            // `Text(_:style:)` interpolation only exists on `LocalizedStringKey`, so the date
            // has to be interpolated directly into a `Text` literal rather than a plain String.
            if let capturedAt {
                Text("Updated \(capturedAt, style: .relative) ago")
            } else {
                Text("No data yet")
            }
        }
        .font(.caption2)
        .monospacedDigit()
        .lineLimit(1)
        .foregroundStyle(Color.white.opacity(0.35))
    }
}

private extension PrinterAMSSnapshot {
    var slotCount: Int { amsUnits.prefix(maxUnitsPerPrinter).reduce(0) { $0 + min($1.trays.count, 4) } }
    var loadedCount: Int {
        amsUnits.prefix(maxUnitsPerPrinter).reduce(0) { $0 + $1.trays.prefix(4).filter { $0.colorHex != nil }.count }
    }
}

// MARK: - Small: one printer, all its units (up to 10 slots)

private struct AMSSmallView: View {
    let printer: PrinterAMSSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            PrinterHeader(printer: printer, trailing: "\(printer.loadedCount)/\(printer.slotCount)")
            PrinterUnits(printer: printer, swatchSize: 27, corner: 7, tagWidth: 15, useLongTag: false, rowSpacing: 7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Medium: up to two printers side by side, every unit

private struct AMSMediumView: View {
    let printers: [PrinterAMSSnapshot]
    let capturedAt: Date?

    private var shown: [PrinterAMSSnapshot] { Array(printers.prefix(maxPrintersShown)) }
    private var hiddenPrinters: Int { max(0, printers.count - maxPrintersShown) }
    private var totalSlots: Int { shown.reduce(0) { $0 + $1.slotCount } }
    private var totalLoaded: Int { shown.reduce(0) { $0 + $1.loadedCount } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 13) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, printer in
                    if index > 0 {
                        Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        PrinterHeader(printer: printer, trailing: printer.stateLabel)
                        PrinterUnits(printer: printer, swatchSize: 26, corner: 7, tagWidth: 14, useLongTag: false, rowSpacing: 6, showsMaterialLabel: true)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }

            HStack(spacing: 8) {
                StaleStamp(capturedAt: capturedAt)
                Spacer(minLength: 0)
                if hiddenPrinters > 0 {
                    Text("+\(hiddenPrinters) printer\(hiddenPrinters == 1 ? "" : "s")")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Text("\(totalSlots) slots · \(totalLoaded) loaded")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Large: printer cards with unit names spelled out, refresh action

private struct AMSLargeView: View {
    let printers: [PrinterAMSSnapshot]
    let capturedAt: Date?

    private var shown: [PrinterAMSSnapshot] { Array(printers.prefix(maxPrintersShown)) }
    private var hiddenPrinters: Int { max(0, printers.count - maxPrintersShown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AMS COLORS")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(Color.white.opacity(0.4))
                Spacer()
                StaleStamp(capturedAt: capturedAt)
            }

            ForEach(Array(shown.enumerated()), id: \.offset) { _, printer in
                VStack(alignment: .leading, spacing: 8) {
                    PrinterHeader(printer: printer, trailing: "\(printer.stateLabel) · \(printer.loadedCount)/\(printer.slotCount) loaded")
                    PrinterUnits(printer: printer, swatchSize: 31, corner: 9, tagWidth: 46, useLongTag: true, rowSpacing: 8, showsMaterialLabel: true)
                }
                .padding(10)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
            }

            Spacer(minLength: 0)

            HStack {
                let printerCount = "\(shown.count)\(hiddenPrinters > 0 ? "+\(hiddenPrinters)" : "") printer\(shown.count == 1 && hiddenPrinters == 0 ? "" : "s")"
                Text("\(printerCount) · \(shown.reduce(0) { $0 + $1.slotCount }) slots")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.4))
                Spacer()
                Button(intent: RefreshAMSIntent()) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(accentBlue)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Entry view

struct AMSWidgetEntryView: View {
    var entry: AMSEntry
    @Environment(\.widgetFamily) private var family

    /// Printing printers first, so Small always shows the one that matters and Medium/Large's
    /// bounded slice never silently drops the printer actually running a job.
    private var ordered: [PrinterAMSSnapshot] {
        entry.printers.sorted { $0.isPrinting && !$1.isPrinting }
    }

    var body: some View {
        Group {
            if ordered.isEmpty {
                emptyState
            } else {
                switch family {
                case .systemSmall:
                    AMSSmallView(printer: ordered[0])
                case .systemLarge:
                    AMSLargeView(printers: ordered, capturedAt: entry.capturedAt)
                default:
                    AMSMediumView(printers: ordered, capturedAt: entry.capturedAt)
                }
            }
        }
        .containerBackground(widgetBG, for: .widget)
        .widgetURL(deepLink)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "printer")
                .font(.title2)
                .foregroundStyle(Color.white.opacity(0.3))
            Text("No printers yet")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.75))
            Text("Open NozzleCast to connect Bambuddy")
                .font(.caption2)
                .multilineTextAlignment(.center)
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
        .description("Shows the filament loaded in every AMS slot.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Previews

#Preview("AMS – Small", as: .systemSmall) {
    AMSWidget()
} timeline: {
    AMSEntry(date: .now, capturedAt: .now.addingTimeInterval(-120), printers: AMSProvider.mockPrinters())
}

#Preview("AMS – Medium", as: .systemMedium) {
    AMSWidget()
} timeline: {
    AMSEntry(date: .now, capturedAt: .now.addingTimeInterval(-120), printers: AMSProvider.mockPrinters())
}

#Preview("AMS – Large", as: .systemLarge) {
    AMSWidget()
} timeline: {
    AMSEntry(date: .now, capturedAt: .now.addingTimeInterval(-120), printers: AMSProvider.mockPrinters())
}

#Preview("AMS – Empty", as: .systemSmall) {
    AMSWidget()
} timeline: {
    AMSEntry(date: .now, capturedAt: nil, printers: [])
}
