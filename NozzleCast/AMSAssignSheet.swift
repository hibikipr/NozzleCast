import SwiftUI

struct AMSAssignSheet: View {
    var printerID: String
    var amsIndex: Int
    var trayIndex: Int
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var pendingSpool: Spool?
    @State private var showMismatchWarning = false

    private var printer: Printer? { store.printer(printerID) }
    private var unit: AMSUnit? { printer?.amsUnits.first { $0.index == amsIndex } }
    private var occupantTray: AMSTray? {
        unit?.trays.first { $0.trayIndex == trayIndex }
    }
    private var occupant: Spool? { store.spool(occupantTray?.spoolID) }

    /// The material the printer itself currently reports for this tray — empty string for a
    /// physically empty slot, matching how Bambuddy phrases its own mismatch warning.
    private var trayMaterial: String { occupantTray?.rawMaterialLabel ?? "" }

    private var slotLabel: String {
        guard let printer, let unit else { return String(localized: "this slot", comment: "Fallback AMS slot reference when no better label is available") }
        let standardUnitOrder = Dictionary(uniqueKeysWithValues: printer.amsUnits.filter { !$0.isHT }.enumerated().map { ($1.id, $0) })
        return unit.displayName(position: standardUnitOrder[unit.id] ?? 0)
    }

    /// Compares material families, not exact strings: a "PLA Matte" spool in a tray the printer
    /// reports as "PLA" is the expected case, not a mismatch (see `MaterialFamily`). An empty tray
    /// still warns, as before.
    private func attemptAssign(_ spool: Spool) {
        if !MaterialFamily.same(trayMaterial, spool.material) {
            pendingSpool = spool
            showMismatchWarning = true
        } else {
            performAssign(spool)
        }
    }

    private func performAssign(_ spool: Spool) {
        store.assign(spoolID: spool.id, toPrinter: printerID, amsIndex: amsIndex, trayIndex: trayIndex)
        dismiss()
    }

    /// Recomputed via `onChange`/`onAppear` on the body below rather than as a computed
    /// property, so this only re-filters when `store.spools` or `searchText` actually change.
    @State private var filteredSpools: [Spool] = []

    private func recomputeFilteredSpools() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            filteredSpools = store.spools
            return
        }
        filteredSpools = store.spools.filter {
            $0.colorName.localizedCaseInsensitiveContains(query)
                || $0.brand.localizedCaseInsensitiveContains(query)
                || $0.material.localizedCaseInsensitiveContains(query)
        }
    }

    private var unitLabel: String {
        guard let printer, printer.amsUnits.count > 1, let unit else { return "" }
        let standardUnitOrder = Dictionary(uniqueKeysWithValues: printer.amsUnits.filter { !$0.isHT }.enumerated().map { ($1.id, $0) })
        return String(localized: "\(unit.displayName(position: standardUnitOrder[unit.id] ?? 0)) · ", comment: "AMS unit label prefix, followed by a slot number")
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 8) {
                Text("\(printer?.name ?? String(localized: "Printer", comment: "Fallback name for a printer with no known name")) · \(unitLabel)Slot \(trayIndex + 1)", comment: "Sheet title: printer name, optional AMS unit, and slot number")
                    .ncFont(size: 17, weight: .bold, relativeTo: .headline)

                if let occupant {
                    HStack(spacing: 8) {
                        occupant.swatch.frame(width: 22, height: 22).clipShape(Circle())
                        Text("\(occupant.materialWithEffect) · \(occupant.colorName)")
                            .ncFont(size: 14, relativeTo: .subheadline)
                            .foregroundStyle(NCColor.textSecondary)
                        Spacer()
                        Button("Remove") {
                            store.unassign(printerID: printerID, amsIndex: amsIndex, trayIndex: trayIndex)
                            dismiss()
                        }
                        .ncFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                        .foregroundStyle(NCColor.destructive)
                    }
                } else if occupantTray?.needsAssignment == true {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(occupantTray?.rawColorHex.map { Color(hex: $0) } ?? NCColor.well)
                            .frame(width: 22, height: 22)
                        Text("\(occupantTray?.rawMaterialLabel ?? String(localized: "Unknown material", comment: "Fallback when the printer hasn't reported what's loaded")) · the printer reports this loaded, but it isn't matched to inventory yet", comment: "AMS slot: raw material label, then explanation that it needs to be matched to an inventory spool")
                            .ncFont(size: 12.5, relativeTo: .footnote)
                            .foregroundStyle(NCColor.statusWarning)
                    }
                } else {
                    Text("Empty slot — assign a spool from inventory")
                        .ncFont(size: 13, relativeTo: .footnote)
                        .foregroundStyle(NCColor.textTertiary)
                }

                // Bambuddy doesn't only record an assignment: it also sends the spool's filament
                // settings to this AMS slot (`ams_filament_setting` + `extrusion_cali_sel`). A
                // printer without Developer LAN mode rejects those and raises "MQTT command
                // verification failed" — confirmed live on an H2C. The assignment still saves, so
                // this explains the fault up front rather than blocking anything.
                if printer?.lacksDeveloperMode == true {
                    Label {
                        Text("Developer LAN mode is off on this printer. Assigning still saves, but the printer will reject the slot settings Bambuddy sends and show an \"MQTT command verification failed\" error.", comment: "Assign sheet note for a printer without Developer LAN mode")
                    } icon: {
                        Image(systemName: "lock.fill")
                    }
                    .ncFont(size: 12, relativeTo: .caption)
                    .foregroundStyle(NCColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            searchField
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            Divider().overlay(Color.white.opacity(0.08))

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredSpools) { spool in
                        Button {
                            attemptAssign(spool)
                        } label: {
                            SpoolRow(spool: spool)
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 20)
                    }

                    if filteredSpools.isEmpty {
                        Text("No spools match \"\(searchText)\".")
                            .ncFont(size: 13, relativeTo: .footnote)
                            .foregroundStyle(NCColor.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                }
            }
        }
        .background(Color(hex: "#212121").ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(24)
        .presentationDragIndicator(.hidden)
        .alert("Material Mismatch", isPresented: $showMismatchWarning, presenting: pendingSpool) { spool in
            Button("Cancel", role: .cancel) {}
            Button("Assign Anyway") { performAssign(spool) }
        } message: { spool in
            Text(
                "The selected spool's material \"\(spool.material)\" doesn't match the tray material \"\(trayMaterial)\" for \(slotLabel). Your server will also set this slot's filament settings on the printer to match the spool, so the printer will treat the slot as \"\(spool.material)\" even though the filament loaded there is unchanged. Assign anyway?",
                comment: "Material mismatch confirmation when assigning a spool whose material differs from what the printer reports for that AMS slot"
            )
        }
        .onAppear { recomputeFilteredSpools() }
        .onChange(of: store.spools) { recomputeFilteredSpools() }
        .onChange(of: searchText) { recomputeFilteredSpools() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(NCColor.textTertiary)
            TextField("Search filament", text: $searchText)
                .ncFont(size: 15, relativeTo: .subheadline)
                .foregroundStyle(.white)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(NCColor.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

private struct SpoolRow: View {
    var spool: Spool
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            spool.swatch
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("\(spool.materialWithEffect) · \(spool.colorName)")
                    .ncFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                    .foregroundStyle(.white)
                Text("\(spool.brand) · \(spool.locationCaption(printerName: store.printerName, amsUnitName: store.amsUnitName))")
                    .ncFont(size: 11.5, relativeTo: .caption)
                    .foregroundStyle(NCColor.textTertiary)
            }

            Spacer()

            Text(Double(spool.remainingPercent) / 100, format: .percent.precision(.fractionLength(0)))
                .ncFont(size: 13, weight: .medium, relativeTo: .footnote)
                .foregroundStyle(NCColor.textSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

#Preview {
    AMSAssignSheet(printerID: MockData.workshopX1C, amsIndex: 0, trayIndex: 0)
        .environment(AppStore(config: BambuddyConfig()))
        .preferredColorScheme(.dark)
}
