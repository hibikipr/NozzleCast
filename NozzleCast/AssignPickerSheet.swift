import SwiftUI

struct AssignPickerSheet: View {
    var spool: Spool
    var onFinished: () -> Void

    @Environment(AppStore.self) private var store
    @State private var selectedPrinterID: String?
    @State private var pendingAssignment: PendingAssignment?
    @State private var showMismatchWarning = false

    private struct PendingAssignment {
        var printerID: String
        var amsIndex: Int
        var trayIndex: Int
        var trayMaterial: String
        var slotLabel: String
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 16)

            if let selectedPrinterID {
                slotStep(printerID: selectedPrinterID)
            } else {
                printerStep
            }
        }
        .background(Color(hex: "#212121").ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(24)
        .presentationDragIndicator(.hidden)
        .alert("Material Mismatch", isPresented: $showMismatchWarning, presenting: pendingAssignment) { pending in
            Button("Cancel", role: .cancel) {}
            Button("Assign Anyway") {
                performAssign(printerID: pending.printerID, amsIndex: pending.amsIndex, trayIndex: pending.trayIndex)
            }
        } message: { pending in
            Text(
                "The selected spool's material \"\(spool.material)\" doesn't match the tray material \"\(pending.trayMaterial)\" for \(pending.slotLabel). Your server will also set this slot's filament settings on the printer to match the spool, so the printer will treat the slot as \"\(spool.material)\" even though the filament loaded there is unchanged. Assign anyway?",
                comment: "Material mismatch confirmation when assigning a spool whose material differs from what the printer reports for that AMS slot"
            )
        }
    }

    private func attemptAssign(printerID: String, unit: AMSUnit, tray: AMSTray, slotLabel: String) {
        let occupant = store.spool(tray.spoolID)
        let rawMaterial = tray.rawMaterialLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingMaterial = (rawMaterial?.isEmpty == false ? rawMaterial : nil) ?? occupant?.material
        if (tray.isLoaded || occupant != nil), let existingMaterial, !MaterialFamily.same(existingMaterial, spool.material) {
            pendingAssignment = PendingAssignment(
                printerID: printerID,
                amsIndex: unit.index,
                trayIndex: tray.trayIndex,
                trayMaterial: existingMaterial,
                slotLabel: slotLabel
            )
            showMismatchWarning = true
        } else {
            performAssign(printerID: printerID, amsIndex: unit.index, trayIndex: tray.trayIndex)
        }
    }

    private func performAssign(printerID: String, amsIndex: Int, trayIndex: Int) {
        store.assign(spoolID: spool.id, toPrinter: printerID, amsIndex: amsIndex, trayIndex: trayIndex)
        onFinished()
    }

    private var printerStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a Printer")
                .ncFont(size: 17, weight: .bold, relativeTo: .headline)
                .padding(.horizontal, 20)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.printers) { printer in
                        Button {
                            selectedPrinterID = printer.id
                        } label: {
                            HStack(spacing: 12) {
                                PrinterThumbnailImage(assetName: printer.imageAssetName)
                                    .frame(width: 30, height: 30)
                                    .padding(4)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(NCColor.printerWell))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(NCColor.printerWellBorder, lineWidth: 1))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(printer.name)
                                        .ncFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                                        .foregroundStyle(.white)
                                    Text(printer.model)
                                        .ncFont(size: 12, relativeTo: .caption)
                                        .foregroundStyle(NCColor.textTertiary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(NCColor.textTertiary)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 20)
                    }
                }
            }
        }
    }

    private func slotStep(printerID: String) -> some View {
        let printer = store.printer(printerID)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button {
                    selectedPrinterID = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .foregroundStyle(NCColor.textSecondary)
                }
                .accessibilityLabel(Text("Back", comment: "Accessibility label for returning to printer selection"))
                Text("\(printer?.name ?? String(localized: "Printer", comment: "Fallback name for a printer with no known name")) · Choose a Slot", comment: "Sheet title: printer name and 'Choose a Slot'")
                    .ncFont(size: 17, weight: .bold, relativeTo: .headline)
            }
            .padding(.horizontal, 20)

            if let printer, printer.lacksDeveloperMode {
                Label {
                    Text("Developer LAN mode is off on this printer. Assigning still saves, but the printer will reject the slot settings your server sends and show an \"MQTT command verification failed\" error.", comment: "Assign sheet note for a printer without Developer LAN mode")
                } icon: {
                    Image(systemName: "lock.fill")
                }
                .ncFont(size: 12, relativeTo: .caption)
                .foregroundStyle(NCColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
            }

            if let printer, printer.amsUnits.isEmpty {
                Text("This printer has no AMS units.")
                    .ncFont(size: 13, relativeTo: .footnote)
                    .foregroundStyle(NCColor.textTertiary)
                    .padding(.horizontal, 20)
            }

            let standardUnitOrder = Dictionary(uniqueKeysWithValues: (printer?.amsUnits ?? []).filter { !$0.isHT }.enumerated().map { ($1.id, $0) })

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(printer?.amsUnits ?? []) { unit in
                        let unitLabel = unit.displayName(position: standardUnitOrder[unit.id] ?? 0)
                        VStack(alignment: .leading, spacing: 8) {
                            if (printer?.amsUnits.count ?? 0) > 1 {
                                Text(unitLabel)
                                    .ncFont(size: 11, weight: .semibold, relativeTo: .caption2)
                                    .foregroundStyle(NCColor.textTertiary)
                            }
                            LazyVGrid(columns: AMSSlotGrid.columns, spacing: 8) {
                                ForEach(unit.trays) { tray in
                                    Button {
                                        attemptAssign(printerID: printerID, unit: unit, tray: tray, slotLabel: unitLabel)
                                    } label: {
                                        AMSSlotCard(spool: store.spool(tray.spoolID), slotIndex: tray.trayIndex, tray: tray, fillsWidth: true)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }

            Spacer()
        }
    }
}
