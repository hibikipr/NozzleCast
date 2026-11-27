import WidgetKit
import SwiftUI
import AppIntents
import NozzleCastShared

// Fixed, not adaptive: NozzleCast forces `.preferredColorScheme(.dark)` everywhere in the app
// (see RootView.swift) and NCColor has no light-mode variants. WidgetKit gives widgets no way
// to force their own color scheme, so the container background is pinned dark here and paired
// with fixed light-on-dark foreground tones, matching how the rest of the app stays single-theme
// rather than mixing in a light appearance nothing else in the product supports.
let widgetBG = Color(red: 0x1a / 255, green: 0x1a / 255, blue: 0x1a / 255)
// Currently only referenced by the commented-out Refresh button in `AMSLargeView`. Kept so the
// button can be restored as-is; not dead code to delete.
let accentBlue = Color(red: 0x4F / 255, green: 0x7F / 255, blue: 0xE0 / 255)
let accentLightBlue = Color(red: 0x8F / 255, green: 0xB4 / 255, blue: 0xFF / 255)
let lowStockOrange = Color(red: 0xF5 / 255, green: 0x9E / 255, blue: 0x0B / 255)
let statusPaused = Color(red: 0xF5 / 255, green: 0x9E / 255, blue: 0x0B / 255)
let amsDeepLink = URL(string: "nozzlecast://monitor")!

/// A widget canvas is fixed, so content is bounded by design, never clipped by WidgetKit.
let maxUnitsPerPrinter = 3   // 2× AMS2 Pro + 1× AMS HT = 9 slots, the real fleet's ceiling

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
///
/// TODO: currently inert, and therefore not rendered — see `AMSLargeView`'s footer.
///
/// Reloading the timeline re-runs `AMSProvider.timeline()` inside *this* extension, which reads
/// `AMSWidgetStore` from the App Group. Only the containing app ever writes that store
/// (`AppStore.refresh()`), so the reload rebuilds a byte-identical entry with an unchanged
/// `capturedAt` — the staleness stamp keeps counting up from the old timestamp and nothing on
/// screen moves. The `reloadTimelines` call is redundant besides: WidgetKit already reloads a
/// widget's timeline once an interactive `AppIntent` finishes.
///
/// Making this real means letting the extension fetch for itself, which needs three things:
///   1. A `keychain-access-groups` entitlement on both the app and this extension (plus a
///      migration of the existing items), since `KeychainStore` writes with no access group
///      today and the two targets otherwise land in separate default groups.
///   2. `BambuddyAPIClient.swift` and `Models.swift` in this target — both are already
///      Foundation-only, so neither needs untangling from the app's UI.
///   3. `AppStore`'s static mapping (`mapPrinter`/`mapSpool`/`makeAMSSnapshots`) extracted into a
///      Foundation-only file, as it currently sits inside a SwiftUI `@Observable` class.
///
/// Then `perform()` becomes fetch → `AMSWidgetStore.save()` → return, and the stamp resets
/// because `lastSavedAt` genuinely moved.
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
        // The mock fallback is deliberately given an age rather than `.now`. `Text(_:style:
        // .relative)` renders two components, so a fresh timestamp reads "0 sec ago" and hides
        // exactly the width that made the medium footer clip to "Updated 10 min, 46...". This is
        // the reported case, and still a plausible age for a gallery preview.
        let capturedAt = stored.isEmpty ? Date.now.addingTimeInterval(-646) : (AMSWidgetStore.lastSavedAt ?? .now)
        return AMSEntry(date: .now, capturedAt: capturedAt, printers: stored.isEmpty ? Self.mockPrinters() : stored)
    }

    func timeline(for configuration: AMSWidgetIntent, in context: Context) async -> Timeline<AMSEntry> {
        let printers = filtered(AMSWidgetStore.load(), by: configuration)
        let entry = AMSEntry(date: .now, capturedAt: AMSWidgetStore.lastSavedAt, printers: printers)
        // App-driven via `WidgetCenter.shared.reloadTimelines`; `StaleStamp` ticks live with `.relative`.
        return Timeline(entries: [entry], policy: .never)
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
                        AMSTraySnapshot(colorHex: "#E8622C", materialLabel: "PLA", isFeeding: true, colorName: "Sunset Orange", remainingGrams: 720, remainingFraction: 0.72, isLow: false),
                        AMSTraySnapshot(colorHex: "#D9E4E8", colorAlpha: 0.18, effectType: "translucent", materialLabel: "PETG", colorName: "Clear", remainingGrams: 120, remainingFraction: 0.12, isLow: true),
                        AMSTraySnapshot(colorHex: "#E8622C", extraColorHexes: ["#D9A426", "#2A5FCC", "#C22A7A"], subtype: "Multicolor", effectType: "multicolor", materialLabel: "PLA", colorName: "Silk Multicolor", remainingGrams: 650, remainingFraction: 0.65, isLow: false),
                        AMSTraySnapshot(colorHex: "#141414", effectType: "sparkle", materialLabel: "PLA", colorName: "Galaxy Black", remainingGrams: 400, remainingFraction: 0.4, isLow: false),
                    ]),
                    AMSUnitSnapshot(displayName: "AMS 2", isHighTemp: false, trays: [
                        AMSTraySnapshot(colorHex: "#2A5FCC", materialLabel: "PLA", colorName: "Cobalt Blue", remainingGrams: 880, remainingFraction: 0.88, isLow: false),
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
                        AMSTraySnapshot(colorHex: "#C22A7A", materialLabel: "PLA", colorName: "Magenta", remainingGrams: 200, remainingFraction: 0.2, isLow: true),
                        AMSTraySnapshot(colorHex: "#D9A426", materialLabel: "PLA", colorName: "Amber Gold", remainingGrams: 540, remainingFraction: 0.54, isLow: false),
                        AMSTraySnapshot(colorHex: nil, materialLabel: nil),
                        AMSTraySnapshot(colorHex: "#F2F2F2", materialLabel: "ABS"),
                    ]),
                    AMSUnitSnapshot(displayName: "AMS-HT", isHighTemp: true, trays: [
                        AMSTraySnapshot(colorHex: "#6E6E6E", materialLabel: "PC"),
                    ]),
                ]
            ),
            // A rack printer's own AMS: seven slots, one per hotend, the fifth one feeding.
            PrinterAMSSnapshot(
                printerName: "Studio P3C",
                stateLabel: "Printing",
                isPrinting: true,
                amsUnits: [
                    AMSUnitSnapshot(displayName: "AMS 3P", isRack: true, trays: [
                        AMSTraySnapshot(colorHex: "#E8622C", materialLabel: "PLA", colorName: "Sunset Orange", remainingGrams: 720, remainingFraction: 0.72, isLow: false),
                        AMSTraySnapshot(colorHex: "#2A5FCC", materialLabel: "PLA", colorName: "Cobalt Blue", remainingGrams: 880, remainingFraction: 0.88, isLow: false),
                        AMSTraySnapshot(colorHex: "#22C55E", materialLabel: "PETG"),
                        AMSTraySnapshot(colorHex: nil, materialLabel: nil),
                        AMSTraySnapshot(colorHex: "#141414", effectType: "sparkle", materialLabel: "PLA", isFeeding: true, colorName: "Galaxy Black", remainingGrams: 400, remainingFraction: 0.4, isLow: false),
                        AMSTraySnapshot(colorHex: "#D9A426", materialLabel: "PLA", colorName: "Amber Gold", remainingGrams: 90, remainingFraction: 0.09, isLow: true),
                        AMSTraySnapshot(colorHex: "#F2F2F2", materialLabel: "ABS"),
                    ]),
                ]
            ),
        ]
    }
}

// MARK: - Shared bits (also used by FilamentStockWidget)

/// A printer's slots, every unit's in order, with what labels each.
struct AMSSlot: Identifiable {
    let id: Int
    let tray: AMSTraySnapshot
    /// "A1", "A2", "HT" — numbered among regular units only.
    let unitTag: String
    /// 1-based within its unit.
    let number: Int
    /// The first slot of a unit after the first, so a rack can draw a divider before it.
    let startsUnit: Bool
}

extension AMSUnitSnapshot {
    /// A regular unit: numbered "A1", "A2", ... among the regular units only.
    var isRegular: Bool { !isHighTemp && !isRack }

    /// "A1", "HT", or a rack AMS's own name ("AMS 3P").
    func tag(regularNumber: Int) -> String {
        if isRack { return displayName }
        return isHighTemp ? "HT" : "A\(regularNumber)"
    }
}

extension PrinterAMSSnapshot {
    var slots: [AMSSlot] {
        var out: [AMSSlot] = []
        var regular = 0
        for (u, unit) in amsUnits.prefix(maxUnitsPerPrinter).enumerated() {
            if unit.isRegular { regular += 1 }
            let tag = unit.tag(regularNumber: regular)
            for (t, tray) in unit.visibleTrays.enumerated() {
                out.append(AMSSlot(id: out.count, tray: tray, unitTag: tag, number: t + 1, startsUnit: u > 0 && t == 0))
            }
        }
        return out
    }

    private var cappedTrays: [AMSTraySnapshot] {
        amsUnits.prefix(maxUnitsPerPrinter).flatMap(\.visibleTrays)
    }

    var slotCount: Int {
        amsUnits.prefix(maxUnitsPerPrinter).reduce(0) { $0 + $1.visibleTrays.count }
    }
    var loadedCount: Int {
        cappedTrays.reduce(0) { $0 + ($1.isEmpty ? 0 : 1) }
    }
    var lowCount: Int {
        cappedTrays.reduce(0) { $0 + ($1.isLow == true ? 1 : 0) }
    }
    var hasLowStock: Bool {
        cappedTrays.contains { $0.isLow == true }
    }
    var hasSeveralUnits: Bool { min(amsUnits.count, maxUnitsPerPrinter) > 1 }

    /// "Feeding slot 2", or "Feeding A2 · 3" on a printer with more than one unit; nil when no slot
    /// is feeding.
    var feedingLabel: String? {
        var regular = 0
        for unit in amsUnits.prefix(maxUnitsPerPrinter) {
            if unit.isRegular { regular += 1 }
            for (t, tray) in unit.visibleTrays.enumerated() where tray.isFeeding == true {
                if hasSeveralUnits {
                    let tag = unit.tag(regularNumber: regular)
                    return String(localized: "Feeding \(tag) · \(t + 1)")
                }
                return String(localized: "Feeding slot \(t + 1)")
            }
        }
        return nil
    }
}

struct PrinterHeader: View {
    let printer: PrinterAMSSnapshot
    var trailing: String?
    var trailingIsAccent = false

    private var dotColor: Color {
        if printer.isPrinting { return accentBlue }
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
                    .font(.caption2.weight(trailingIsAccent ? .semibold : .regular))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .foregroundStyle(trailingIsAccent ? accentLightBlue : Color.white.opacity(0.45))
            }
        }
    }
}

struct StaleStamp: View {
    let capturedAt: Date?
    /// Drops the leading "Updated" where space is short.
    var compact: Bool = false

    var body: some View {
        Group {
            // `.relative` on purpose: it keeps counting between timeline reloads, which are 30
            // minutes apart, so the stamp can't claim "0 min ago" half an hour later.
            if let capturedAt {
                if compact {
                    Text("\(capturedAt, style: .relative) ago")
                } else {
                    Text("Updated \(capturedAt, style: .relative) ago")
                }
            } else {
                Text("No data yet")
            }
        }
        .font(.caption2)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.9)
        .foregroundStyle(Color.white.opacity(0.35))
    }
}

/// The swatch for one slot: the spool's colour and effect, or a dashed outline when empty.
struct SlotSwatch<S: Shape>: View {
    var tray: AMSTraySnapshot
    var shape: S

    var body: some View {
        if let hex = tray.colorHex {
            FilamentSwatchView(colorHex: hex, alpha: tray.colorAlpha, extraColorHexes: tray.extraColorHexes, subtype: tray.subtype, effectType: tray.effectType)
                .clipShape(shape)
                .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 0.75))
        } else {
            shape.fill(Color.white.opacity(0.03))
                .overlay(shape.stroke(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3])))
        }
    }
}

// MARK: - Spool Rack

/// A slot drawn as a spool seen side-on: the filament's colour (and effect) as a ring round a dark
/// hub. The feeding slot gets a glowing outer ring.
private struct SpoolDisc: View {
    let tray: AMSTraySnapshot

    var body: some View {
        ZStack {
            SlotSwatch(tray: tray, shape: Circle())
            if !tray.isEmpty, tray.colorHex != nil {
                GeometryReader { proxy in
                    let hub = proxy.size.width * 0.36
                    Circle()
                        .fill(Color(white: 0.16))
                        .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))
                        .frame(width: hub, height: hub)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .padding(tray.isFeeding == true ? 3 : 0)
        .overlay {
            if tray.isFeeding == true {
                Circle().stroke(accentLightBlue, lineWidth: 2)
                    .shadow(color: accentBlue.opacity(0.9), radius: 5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tray.isEmpty ? String(localized: "Empty slot") : [tray.materialLabel, tray.colorName, tray.isFeeding == true ? String(localized: "feeding") : nil].compactMap { $0 }.joined(separator: ", "))
    }
}

/// One printer's slots in a row, each capped at `maxDisc`, with a divider between units and,
/// optionally, the material under each.
private struct SpoolRow: View {
    let printer: PrinterAMSSnapshot
    let maxDisc: CGFloat
    var showsMaterial = true

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(printer.slots) { slot in
                if slot.startsUnit {
                    Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: maxDisc * 0.8)
                }
                VStack(spacing: 4) {
                    SpoolDisc(tray: slot.tray)
                        .frame(maxWidth: maxDisc, maxHeight: maxDisc)
                    if showsMaterial {
                        Text(slot.tray.isEmpty ? String(localized: "Empty") : (MaterialLabel.short(slot.tray.materialLabel) ?? "—"))
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Color.white.opacity(slot.tray.isEmpty ? 0.35 : 0.6))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Small: one printer, its slots as a grid of spools.
private struct AMSSmallView: View {
    let printer: PrinterAMSSnapshot

    var body: some View {
        let slots = printer.slots
        let columns = slots.count <= 4 ? 2 : 3
        let feeding = printer.feedingLabel
        let loaded = slots.reduce(0) { $0 + ($1.tray.isEmpty ? 0 : 1) }

        VStack(alignment: .leading, spacing: 6) {
            PrinterHeader(printer: printer, trailing: "\(loaded)/\(slots.count)")
            Text(feeding ?? printer.stateLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(feeding != nil ? accentLightBlue : Color.white.opacity(0.45))
                .lineLimit(1)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 6) {
                ForEach(slots) { slot in
                    SpoolDisc(tray: slot.tray)
                        .frame(maxWidth: columns == 2 ? 42 : 30)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Medium: one printer with its materials, or two as compact rows.
private struct AMSMediumView: View {
    let printers: [PrinterAMSSnapshot]
    let capturedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if printers.count == 1, let printer = printers.first {
                let feeding = printer.feedingLabel
                PrinterHeader(printer: printer, trailing: feeding ?? printer.stateLabel, trailingIsAccent: feeding != nil)
                Spacer(minLength: 0)
                SpoolRow(printer: printer, maxDisc: 48)
                Spacer(minLength: 0)
                StaleStamp(capturedAt: capturedAt)
            } else {
                ForEach(Array(printers.prefix(2).enumerated()), id: \.offset) { index, printer in
                    if index > 0 { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
                    let feeding = printer.feedingLabel
                    VStack(alignment: .leading, spacing: 5) {
                        PrinterHeader(printer: printer, trailing: feeding ?? printer.stateLabel, trailingIsAccent: feeding != nil)
                        SpoolRow(printer: printer, maxDisc: 30, showsMaterial: false)
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    StaleStamp(capturedAt: capturedAt, compact: true)
                    Spacer()
                    if printers.count > 2 {
                        Text("+^[\(printers.count - 2) printer](inflect: true)", comment: "AMS widget: printers that didn't fit")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.5))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Large: up to two printers as full racks, up to two more as one-line rows.
private struct AMSLargeView: View {
    let printers: [PrinterAMSSnapshot]
    let capturedAt: Date?

    private var full: [PrinterAMSSnapshot] { Array(printers.prefix(2)) }
    private var compact: [PrinterAMSSnapshot] { Array(printers.dropFirst(2).prefix(2)) }
    private var hidden: Int { max(0, printers.count - 4) }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("AMS COLORS")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(Color.white.opacity(0.4))
                Spacer()
                StaleStamp(capturedAt: capturedAt)
            }
            ForEach(Array(full.enumerated()), id: \.offset) { index, printer in
                if index > 0 { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
                let feeding = printer.feedingLabel
                VStack(alignment: .leading, spacing: 8) {
                    PrinterHeader(printer: printer, trailing: feeding ?? printer.stateLabel, trailingIsAccent: feeding != nil)
                    SpoolRow(printer: printer, maxDisc: 50)
                }
            }
            ForEach(Array(compact.enumerated()), id: \.offset) { _, printer in
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                HStack(spacing: 6) {
                    Text(printer.printerName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.75))
                        .lineLimit(1)
                    Text(printer.stateLabel)
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.45))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ForEach(printer.slots.prefix(9)) { slot in
                        SpoolDisc(tray: slot.tray).frame(width: 20, height: 20)
                    }
                }
            }
            Spacer(minLength: 0)
            if hidden > 0 {
                Text("+^[\(hidden) more printer](inflect: true)", comment: "AMS widget: printers that didn't fit")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.4))
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
        .widgetURL(amsDeepLink)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "printer")
                .font(.title2)
                .foregroundStyle(Color.white.opacity(0.3))
            Text("No printers yet")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.75))
            Text("Open NozzleCast to connect a server")
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
    // -3599s is the widest `.relative` gets: below an hour it prints two components
    // ("59 min, 59 sec ago"), above it collapses to the shorter "1 hr, 2 min ago".
    AMSEntry(date: .now, capturedAt: .now.addingTimeInterval(-3599), printers: AMSProvider.mockPrinters())
}

#Preview("AMS – Medium", as: .systemMedium) {
    AMSWidget()
} timeline: {
    // -3599s is the widest `.relative` gets: below an hour it prints two components
    // ("59 min, 59 sec ago"), above it collapses to the shorter "1 hr, 2 min ago".
    AMSEntry(date: .now, capturedAt: .now.addingTimeInterval(-3599), printers: AMSProvider.mockPrinters())
}

#Preview("AMS – Large", as: .systemLarge) {
    AMSWidget()
} timeline: {
    // -3599s is the widest `.relative` gets: below an hour it prints two components
    // ("59 min, 59 sec ago"), above it collapses to the shorter "1 hr, 2 min ago".
    AMSEntry(date: .now, capturedAt: .now.addingTimeInterval(-3599), printers: AMSProvider.mockPrinters())
}

#Preview("AMS – Empty", as: .systemSmall) {
    AMSWidget()
} timeline: {
    AMSEntry(date: .now, capturedAt: nil, printers: [])
}
