import SwiftUI

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
                    colorSection
                    filamentSection
                    weightCostSection
                    tempSection
                    notesSection
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
            labeledField("Category", text: $category)
        }
    }

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
