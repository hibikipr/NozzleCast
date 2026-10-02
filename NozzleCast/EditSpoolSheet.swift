import SwiftUI
import NozzleCastShared

/// Edits a spool's own inventory record — material, color, brand, weight, cost, notes. This is
/// bookkeeping only (same PATCH Bambuddy's own edit screen uses); it doesn't push anything to
/// physical AMS hardware. A step toward eventually supporting Bambuddy's `configure` flow, which
/// needs accurate material/color/temp data on the spool record to work from.
struct EditSpoolSheet: View {
    var spool: Spool
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var material: String
    @State private var colorName: String
    @State private var colorHex: String
    @State private var extraColorsText: String
    @State private var brand: String
    @State private var subtype: String
    @State private var netWeightGrams: String
    @State private var nozzleTempMin: String
    @State private var nozzleTempMax: String
    @State private var costPerKg: String
    @State private var category: String
    @State private var note: String

    /// Common Bambu-ecosystem materials, offered as suggestions — Bambuddy itself accepts any
    /// material string, this is just a starting list so the field isn't blank on first use.
    private static let commonMaterials = ["PLA", "PETG", "ABS", "ASA", "TPU", "PC", "PA", "PA-CF", "PAHT-CF", "PVA", "HIPS", "PET-CF"]

    init(spool: Spool) {
        self.spool = spool
        _material = State(initialValue: spool.material)
        _colorName = State(initialValue: spool.colorName)
        _colorHex = State(initialValue: spool.colorHex)
        _extraColorsText = State(initialValue: spool.extraColorHexes.joined(separator: ","))
        _brand = State(initialValue: spool.brand)
        _subtype = State(initialValue: spool.subtype ?? "")
        _netWeightGrams = State(initialValue: String(spool.netWeightGrams))
        _nozzleTempMin = State(initialValue: spool.nozzleTempMin.map(String.init) ?? "")
        _nozzleTempMax = State(initialValue: spool.nozzleTempMax.map(String.init) ?? "")
        _costPerKg = State(initialValue: spool.costPerKg.map { String(format: "%.2f", $0) } ?? "")
        _category = State(initialValue: spool.category ?? "")
        _note = State(initialValue: spool.note ?? "")
    }

    /// Existing brands/subtypes across the whole inventory, offered as suggestions — matching
    /// Bambuddy's own "type it or pick a value you've already used" behavior.
    private var knownBrands: [String] {
        Array(Set(store.spools.map(\.brand).filter { !$0.isEmpty })).sorted()
    }
    private var knownSubtypes: [String] {
        Array(Set(store.spools.compactMap(\.subtype).filter { !$0.isEmpty })).sorted()
    }

    private var extraColorHexes: [String] {
        extraColorsText.split(separator: ",").compactMap { part in
            let hex = part.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            return hex.isEmpty ? nil : "#" + hex.uppercased()
        }
    }

    private var canSave: Bool {
        !colorName.trimmingCharacters(in: .whitespaces).isEmpty
            && !brand.trimmingCharacters(in: .whitespaces).isEmpty
            && !material.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    stockSection
                    colorSection
                    filamentSection
                    weightCostSection
                    // Spoolman stores no per-spool nozzle temperatures — see `isSpoolman`.
                    if !isSpoolman { tempSection }
                    notesSection
                    if spool.materialNumber != nil || !spool.suppliers.isEmpty { purchasingSection }
                    usageSection
                    removeSection
                }
                .padding(16)
                .padding(.bottom, 40)
            }
            .background(Color(hex: "#212121").ignoresSafeArea())
            .navigationTitle("Edit Spool")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
        .preferredColorScheme(.dark)
        .confirmationDialog(
            Text("Delete this spool?", comment: "Delete spool confirmation title"),
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                store.deleteSpool(spool.id)
                dismiss()
            } label: {
                Text("Delete Permanently", comment: "Delete spool confirmation button")
            }
            Button(role: .cancel) {} label: { Text("Cancel") }
        } message: {
            Text("\(spool.brand) \(spool.material) \(spool.colorName) will be removed from your inventory for good, including its usage history. Archive it instead to keep the record.", comment: "Delete spool confirmation message")
        }
    }

    @State private var isConfirmingDelete = false
    /// Nil while loading or when there's no history to show (demo data, Spoolman mode).
    @State private var usage: [SpoolUsageRecord]?
    @State private var usageLoaded = false

    /// The current spool from the store, so the stock line and the shopping-list button follow
    /// changes made while the sheet is open (`spool` is the snapshot it was opened with).
    private var current: Spool { store.spool(spool.id) ?? spool }

    /// What's left, whether it's running low, when it was last used, and the way to restock it.
    private var stockSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stock", comment: "Spool screen section: remaining filament").sectionEyebrow()
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(current.remainingGrams) g left", comment: "Grams of filament remaining on a spool")
                        .ncFont(size: 20, weight: .semibold, relativeTo: .title3)
                        .foregroundStyle(.white)
                    Text("of \(current.netWeightGrams) g", comment: "Spool label weight, after the grams remaining")
                        .ncFont(size: 14, relativeTo: .subheadline)
                        .foregroundStyle(NCColor.textTertiary)
                    Spacer()
                    RemainingLabel(spool: current, size: 14)
                }
                if current.isLowStock {
                    Label("Running low", systemImage: "exclamationmark.triangle.fill")
                        .ncFont(size: 13, weight: .medium, relativeTo: .footnote)
                        .foregroundStyle(NCColor.statusWarning)
                }
                if let lastUsedAt = current.lastUsedAt {
                    Text("Last used \(lastUsedAt.formatted(.relative(presentation: .named)))", comment: "When a spool was last used in a print")
                        .ncFont(size: 12.5, relativeTo: .caption)
                        .foregroundStyle(NCColor.textTertiary)
                }
                if let item = store.shoppingListItem(for: current) {
                    Label(String(localized: "On your shopping list · \(item.status.title)", comment: "Spool's filament is on the shopping list, with its status"), systemImage: "cart.fill")
                        .ncFont(size: 13, weight: .medium, relativeTo: .footnote)
                        .foregroundStyle(NCColor.accentLight)
                        .padding(.top, 2)
                } else {
                    Button {
                        store.addToShoppingList(current)
                    } label: {
                        Label("Add to Shopping List", systemImage: "cart.badge.plus")
                            .ncFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(NCColor.accentLight)
                    .padding(.top, 2)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))
        }
    }

    /// Material number and suppliers (Bambuddy 1.2.5.7). Read-only here; they're edited in
    /// Bambuddy, where the supplier records live.
    private var purchasingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Purchasing", comment: "Spool screen section: material number and suppliers").sectionEyebrow()
            VStack(alignment: .leading, spacing: 10) {
                if let materialNumber = spool.materialNumber {
                    detailRow(String(localized: "Material number", comment: "Manufacturer's article number for a filament"), value: materialNumber)
                }
                ForEach(spool.suppliers, id: \.self) { supplier in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(supplier.name)
                                .ncFont(size: 14, weight: .medium, relativeTo: .subheadline)
                                .foregroundStyle(.white)
                            if supplier.isPurchaseSource {
                                Text("Bought here", comment: "Badge on the supplier a spool was bought from")
                                    .ncFont(size: 10.5, weight: .semibold, relativeTo: .caption2)
                                    .foregroundStyle(NCColor.accentLight)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(NCColor.accent.opacity(0.2)))
                            }
                        }
                        let details = [
                            supplier.articleNumber.map { String(localized: "Article \($0)", comment: "Supplier's article number") },
                            supplier.pricePerKg.map { String(localized: "\($0, format: .number.precision(.fractionLength(2)))/kg", comment: "Supplier price per kilogram") },
                        ].compactMap { $0 }
                        if !details.isEmpty {
                            Text(details.joined(separator: " · "))
                                .ncFont(size: 12, relativeTo: .caption)
                                .foregroundStyle(NCColor.textTertiary)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(NCColor.textSecondary)
            Spacer()
            Text(value)
                .foregroundStyle(.white)
                .textSelection(.enabled)
        }
        .ncFont(size: 14, relativeTo: .subheadline)
    }

    /// The prints that used this spool. Hidden where Bambuddy keeps no per-spool history.
    @ViewBuilder
    private var usageSection: some View {
        Group {
            if let usage {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Usage", comment: "Spool screen section: prints that used this spool").sectionEyebrow()
                    if usage.isEmpty {
                        Text("No prints have used this spool yet.", comment: "Spool usage history is empty")
                            .ncFont(size: 13, relativeTo: .footnote)
                            .foregroundStyle(NCColor.textTertiary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(usage) { record in
                                usageRow(record)
                                if record.id != usage.last?.id {
                                    Divider().overlay(Color.white.opacity(0.06))
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))
                    }
                }
            } else if !usageLoaded {
                ProgressView().tint(NCColor.accentLight).frame(maxWidth: .infinity)
            }
        }
        .task {
            usage = await store.spoolUsage(spool.id)
            usageLoaded = true
        }
    }

    private func usageRow(_ record: SpoolUsageRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.printName)
                    .ncFont(size: 14, relativeTo: .subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                let when = record.date?.formatted(date: .abbreviated, time: .omitted)
                let parts = [when, record.printerName, record.outcome == .completed ? nil : String(localized: "not completed", comment: "Spool usage row: the print failed or was cancelled")].compactMap { $0 }
                if !parts.isEmpty {
                    Text(parts.joined(separator: " · "))
                        .ncFont(size: 12, relativeTo: .caption)
                        .foregroundStyle(NCColor.textTertiary)
                }
            }
            Spacer(minLength: 8)
            Text("\(record.grams, format: .number.precision(.fractionLength(record.grams < 10 ? 1 : 0))) g", comment: "Grams a print used from a spool")
                .ncFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                .foregroundStyle(NCColor.textSecondary)
        }
        .padding(.vertical, 10)
    }

    /// Archive (reversible — the inventory shows an Undo bar) and permanent delete, kept at the
    /// bottom of the sheet away from the fields and from Save.
    private var removeSection: some View {
        VStack(spacing: 10) {
            Button {
                store.archiveSpool(spool.id)
                dismiss()
            } label: {
                Label("Archive Spool", systemImage: "archivebox")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)

            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label("Delete Spool…", systemImage: "trash")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(NCColor.statusError.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(NCColor.statusError)
        }
        .ncFont(size: 15, weight: .semibold, relativeTo: .subheadline)
        .padding(.top, 8)
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Color").sectionEyebrow()
            HStack(spacing: 12) {
                ColorPicker("", selection: colorBinding, supportsOpacity: false)
                    .labelsHidden()
                Text(colorHex.uppercased())
                    .ncFont(size: 14, relativeTo: .subheadline)
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))

            labeledField("Color name", text: $colorName)

            if !isSpoolman {
            VStack(alignment: .leading, spacing: 6) {
                Text("Extra colors")
                    .ncFont(size: 12, weight: .medium, relativeTo: .caption)
                    .foregroundStyle(NCColor.textSecondary)
                TextField("Comma-separated hex stops, e.g. EC984C,6CD4BC", text: $extraColorsText)
                    .ncFont(size: 14, relativeTo: .subheadline)
                    .foregroundStyle(.white)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))

                if !extraColorHexes.isEmpty {
                    FilamentSwatchView(
                        colorHex: colorHex,
                        alpha: spool.colorAlpha,
                        extraColorHexes: extraColorHexes,
                        subtype: subtype.isEmpty ? nil : subtype,
                        effectType: spool.effectType
                    )
                    .frame(height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                Text("For a dual/multi-color or gradient-effect spool. Leave blank for a plain single color.")
                    .ncFont(size: 11, relativeTo: .caption2)
                    .foregroundStyle(NCColor.textTertiary)
            }
            }
        }
    }

    private var filamentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Filament").sectionEyebrow()
            comboField("Material", text: $material, suggestions: Self.commonMaterials)
            comboField("Brand", text: $brand, suggestions: knownBrands)
            comboField("Subtype (e.g. \"PLA Basic\", \"PETG HF\")", text: $subtype, suggestions: knownSubtypes)
        }
    }

    private var weightCostSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Weight & Cost").sectionEyebrow()
            HStack(spacing: 12) {
                labeledField("Label weight (g)", text: $netWeightGrams, keyboardType: .numberPad)
                labeledField("Cost per kg", text: $costPerKg, keyboardType: .decimalPad)
            }
            if !isSpoolman {
                labeledField("Category", text: $category)
            }
        }
    }

    /// True when Bambuddy serves its inventory from Spoolman. Spoolman's spool record has no
    /// field for extra color stops, nozzle temperatures or a category, and Bambuddy's Spoolman
    /// proxy drops them on save — so those fields are hidden there rather than shown and then
    /// silently discarded. Everything else edits the same way in both modes.
    private var isSpoolman: Bool { store.inventoryBackend == .spoolman }

    private var tempSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nozzle Temperature").sectionEyebrow()
            HStack(spacing: 12) {
                labeledField("Min °C", text: $nozzleTempMin, keyboardType: .numberPad)
                labeledField("Max °C", text: $nozzleTempMax, keyboardType: .numberPad)
            }
            Text("Used for future AMS slot configuration — matching this to the spool's real print temperature matters once that's wired up.")
                .ncFont(size: 11.5, relativeTo: .caption)
                .foregroundStyle(NCColor.textTertiary)
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notes").sectionEyebrow()
            TextField("Any additional notes about this spool…", text: $note, axis: .vertical)
                .ncFont(size: 14, relativeTo: .subheadline)
                .foregroundStyle(.white)
                .lineLimit(3...6)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
        }
    }

    /// A field you can type freely into, with a trailing menu of suggested existing values —
    /// matching Bambuddy's own material/brand/subtype inputs (free text, but pick from what's
    /// already known works too).
    private func comboField(_ title: String, text: Binding<String>, suggestions: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .ncFont(size: 12, weight: .medium, relativeTo: .caption)
                .foregroundStyle(NCColor.textSecondary)
            HStack(spacing: 8) {
                TextField("", text: text)
                    .ncFont(size: 15, relativeTo: .subheadline)
                    .foregroundStyle(.white)
                    .autocorrectionDisabled()

                if !suggestions.isEmpty {
                    Menu {
                        ForEach(suggestions, id: \.self) { value in
                            Button(value) { text.wrappedValue = value }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(NCColor.textTertiary)
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
        }
    }

    private func labeledField(_ title: String, text: Binding<String>, keyboardType: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .ncFont(size: 12, weight: .medium, relativeTo: .caption)
                .foregroundStyle(NCColor.textSecondary)
            TextField("", text: text)
                .keyboardType(keyboardType)
                .ncFont(size: 15, relativeTo: .subheadline)
                .foregroundStyle(.white)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: colorHex) },
            set: { colorHex = $0.toHexString() }
        )
    }

    private func save() {
        store.updateSpool(
            spool.id,
            material: material.trimmingCharacters(in: .whitespaces),
            colorName: colorName.trimmingCharacters(in: .whitespaces),
            colorHex: colorHex,
            extraColorHexes: extraColorHexes,
            brand: brand.trimmingCharacters(in: .whitespaces),
            subtype: subtype.trimmingCharacters(in: .whitespaces).isEmpty ? nil : subtype.trimmingCharacters(in: .whitespaces),
            netWeightGrams: Int(netWeightGrams) ?? spool.netWeightGrams,
            nozzleTempMin: Int(nozzleTempMin),
            nozzleTempMax: Int(nozzleTempMax),
            costPerKg: Double(costPerKg),
            category: category.trimmingCharacters(in: .whitespaces).isEmpty ? nil : category.trimmingCharacters(in: .whitespaces),
            note: note.trimmingCharacters(in: .whitespaces).isEmpty ? nil : note.trimmingCharacters(in: .whitespaces)
        )
        dismiss()
    }
}

#Preview {
    EditSpoolSheet(spool: MockData.makeSpools()[0])
        .environment(AppStore(config: BambuddyConfig()))
        .preferredColorScheme(.dark)
}
