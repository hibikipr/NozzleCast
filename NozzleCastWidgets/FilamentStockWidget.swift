import WidgetKit
import SwiftUI
import NozzleCastShared

/// "Will this spool last?": each AMS slot with its colour name and what's left, a bar that turns
/// orange below the spool's low-stock level, and a count of low spools. Same data, timeline and
/// printer choice as the AMS Colors widget (`AMSProvider`), drawn for stock instead of colour.
/// A slot without an inventory spool shows its material only.

// MARK: - Pieces

/// "720g", or nil when the slot has no inventory spool.
private func grams(_ tray: AMSTraySnapshot) -> String? {
    tray.remainingGrams.map { "\($0)g" }
}

private func spokenStock(_ tray: AMSTraySnapshot) -> String {
    if tray.isEmpty { return String(localized: "Empty slot") }
    var parts = [tray.materialLabel, tray.colorName].compactMap { $0 }
    if let g = tray.remainingGrams { parts.append(String(localized: "\(g) grams left")) }
    if tray.isLow == true { parts.append(String(localized: "low")) }
    return parts.joined(separator: ", ")
}

/// Small: a ring per slot that empties as the spool does, the spool's colour inside.
private struct StockRing: View {
    let tray: AMSTraySnapshot
    let size: CGFloat

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                if tray.isEmpty {
                    Circle().stroke(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                } else {
                    Circle().stroke(Color.white.opacity(0.1), lineWidth: 4)
                    if let fraction = tray.remainingFraction {
                        Circle()
                            .trim(from: 0, to: max(fraction, 0.02))
                            .stroke(tray.isLow == true ? lowStockOrange : accentBlue, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    SlotSwatch(tray: tray, shape: Circle())
                        .padding(6)
                }
            }
            .frame(width: size, height: size)
            Text(tray.isEmpty ? String(localized: "Empty") : (grams(tray) ?? MaterialLabel.short(tray.materialLabel) ?? "—"))
                .font(.system(size: 9.5, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(tray.isLow == true ? lowStockOrange : Color.white.opacity(0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenStock(tray))
    }
}

/// Medium and large: swatch, "PLA Sunset Orange", the bar, grams.
private struct StockRow: View {
    let tray: AMSTraySnapshot

    var body: some View {
        HStack(spacing: 8) {
            SlotSwatch(tray: tray, shape: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .frame(width: 18, height: 18)
            if tray.isEmpty {
                Text("Empty slot")
                    .font(.caption2.italic())
                    .foregroundStyle(Color.white.opacity(0.4))
                Spacer(minLength: 0)
            } else {
                (Text(MaterialLabel.short(tray.materialLabel) ?? "—").fontWeight(.semibold).foregroundColor(.white)
                 + Text(tray.colorName.map { " " + $0 } ?? "").foregroundColor(Color.white.opacity(0.45)))
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(width: 128, alignment: .leading)
                if let fraction = tray.remainingFraction {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.1))
                            Capsule()
                                .fill(tray.isLow == true ? lowStockOrange : accentBlue)
                                .frame(width: max(proxy.size.width * fraction, 3))
                        }
                    }
                    .frame(height: 5)
                    Text(grams(tray) ?? "")
                        .font(.caption2.weight(tray.isLow == true ? .bold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(tray.isLow == true ? lowStockOrange : Color.white.opacity(0.6))
                        .frame(width: 42, alignment: .trailing)
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenStock(tray))
    }
}

private struct LowBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count) low")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(lowStockOrange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(lowStockOrange.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

// MARK: - Sizes

private struct StockSmallView: View {
    let printer: PrinterAMSSnapshot

    private var columns: Int { printer.slotCount <= 4 ? 2 : 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(printer.printerName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                LowBadge(count: printer.lowCount)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
                ForEach(printer.slots) { slot in
                    StockRing(tray: slot.tray, size: columns == 2 ? 44 : 30)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Up to `rowLimit` rows across the printers (each printer's name counts as one), then
/// "+N more slots".
private struct StockList: View {
    let printers: [PrinterAMSSnapshot]
    let rowLimit: Int
    var showsPrinterNames: Bool

    private var shown: [(printer: PrinterAMSSnapshot, slots: [AMSSlot])] {
        var left = rowLimit
        var out: [(PrinterAMSSnapshot, [AMSSlot])] = []
        for printer in printers {
            let header = showsPrinterNames ? 1 : 0
            guard left > header else { break }
            let take = min(printer.slots.count, left - header)
            out.append((printer, Array(printer.slots.prefix(take))))
            left -= header + take
        }
        return out
    }

    private var hidden: Int {
        printers.reduce(0) { $0 + $1.slotCount } - shown.reduce(0) { $0 + $1.slots.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, entry in
                if showsPrinterNames {
                    if index > 0 { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.vertical, 2) }
                    PrinterHeader(printer: entry.printer, trailing: nil)
                }
                ForEach(entry.slots) { slot in StockRow(tray: slot.tray) }
            }
            if hidden > 0 {
                Text("+^[\(hidden) more slot](inflect: true)", comment: "Filament Stock widget: slots that didn't fit")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.4))
            }
        }
    }
}

private struct StockMediumView: View {
    let printer: PrinterAMSSnapshot
    let capturedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                PrinterHeader(printer: printer, trailing: nil)
                LowBadge(count: printer.lowCount)
            }
            StockList(printers: [printer], rowLimit: 4, showsPrinterNames: false)
            Spacer(minLength: 0)
            StaleStamp(capturedAt: capturedAt, compact: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct StockLargeView: View {
    let printers: [PrinterAMSSnapshot]
    let capturedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("FILAMENT IN AMS")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(Color.white.opacity(0.4))
                Spacer()
                LowBadge(count: printers.reduce(0) { $0 + $1.lowCount })
            }
            StockList(printers: printers, rowLimit: 11, showsPrinterNames: true)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                StaleStamp(capturedAt: capturedAt)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Entry & widget

struct FilamentStockEntryView: View {
    var entry: AMSEntry
    @Environment(\.widgetFamily) private var family

    /// Printers with low spools first, then printing ones.
    private var ordered: [PrinterAMSSnapshot] {
        entry.printers.sorted { a, b in
            if (a.lowCount > 0) != (b.lowCount > 0) { return a.lowCount > 0 }
            return a.isPrinting && !b.isPrinting
        }
    }

    var body: some View {
        Group {
            if let first = ordered.first {
                switch family {
                case .systemSmall: StockSmallView(printer: first)
                case .systemLarge: StockLargeView(printers: ordered, capturedAt: entry.capturedAt)
                default: StockMediumView(printer: first, capturedAt: entry.capturedAt)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "printer")
                        .font(.title2)
                        .foregroundStyle(Color.white.opacity(0.3))
                    Text("Open NozzleCast to see your filament")
                        .font(.caption.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.white.opacity(0.75))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .containerBackground(widgetBG, for: .widget)
        .widgetURL(amsDeepLink)
    }
}

struct FilamentStockWidget: Widget {
    let kind = "FilamentStockWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: AMSWidgetIntent.self, provider: AMSProvider()) { entry in
            FilamentStockEntryView(entry: entry)
        }
        .configurationDisplayName("Filament Stock")
        .description("What's left on each spool in your AMS, and which are running low.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

#Preview("Stock – Small", as: .systemSmall) {
    FilamentStockWidget()
} timeline: {
    AMSEntry(date: .now, capturedAt: .now.addingTimeInterval(-240), printers: AMSProvider.mockPrinters())
}

#Preview("Stock – Medium", as: .systemMedium) {
    FilamentStockWidget()
} timeline: {
    AMSEntry(date: .now, capturedAt: .now.addingTimeInterval(-240), printers: AMSProvider.mockPrinters())
}

#Preview("Stock – Large", as: .systemLarge) {
    FilamentStockWidget()
} timeline: {
    AMSEntry(date: .now, capturedAt: .now.addingTimeInterval(-240), printers: AMSProvider.mockPrinters())
}
