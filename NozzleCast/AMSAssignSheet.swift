import SwiftUI

struct AMSAssignSheet: View {
    var printerID: String
    var amsIndex: Int
    var trayIndex: Int
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var printer: Printer? { store.printer(printerID) }
    private var unit: AMSUnit? { printer?.amsUnits.first { $0.index == amsIndex } }
    private var occupantSpoolID: String? {
        unit?.trays.first { $0.trayIndex == trayIndex }?.spoolID
    }
    private var occupant: Spool? { store.spool(occupantSpoolID) }

    private var unitLabel: String {
        guard let printer, printer.amsUnits.count > 1, let unit else { return "" }
        let standardUnitOrder = Dictionary(uniqueKeysWithValues: printer.amsUnits.filter { !$0.isHT }.enumerated().map { ($1.id, $0) })
        return unit.displayName(position: standardUnitOrder[unit.id] ?? 0) + " · "
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 8) {
                Text("\(printer?.name ?? "Printer") · \(unitLabel)Slot \(trayIndex + 1)")
                    .font(.system(size: 17, weight: .bold))

                if let occupant {
                    HStack(spacing: 8) {
                        Circle().fill(Color(hex: occupant.colorHex)).frame(width: 22, height: 22)
                        Text("\(occupant.material.rawValue) · \(occupant.colorName)")
                            .font(.system(size: 14))
                            .foregroundStyle(NCColor.textSecondary)
                        Spacer()
                        Button("Remove") {
                            store.unassign(printerID: printerID, amsIndex: amsIndex, trayIndex: trayIndex)
                            dismiss()
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(NCColor.destructive)
                    }
                } else {
                    Text("Empty slot — assign a spool from inventory")
                        .font(.system(size: 13))
                        .foregroundStyle(NCColor.textTertiary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider().overlay(Color.white.opacity(0.08))

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.spools) { spool in
                        Button {
                            store.assign(spoolID: spool.id, toPrinter: printerID, amsIndex: amsIndex, trayIndex: trayIndex)
                            dismiss()
                        } label: {
                            SpoolRow(spool: spool)
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 20)
                    }
                }
            }
        }
        .background(Color(hex: "#212121").ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(24)
        .presentationDragIndicator(.hidden)
    }
}

private struct SpoolRow: View {
    var spool: Spool
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(hex: spool.colorHex))
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(spool.material.rawValue) · \(spool.colorName)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("\(spool.brand) · \(spool.locationCaption(printerName: store.printerName))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(NCColor.textTertiary)
            }

            Spacer()

            Text("\(spool.remainingPercent)%")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(NCColor.textSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
