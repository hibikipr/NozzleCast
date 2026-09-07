import SwiftUI

enum InventoryFilter: Hashable, CaseIterable {
    case all, inAMS, inStorage, pla, petg, abs, tpu

    var title: String {
        switch self {
        case .all: String(localized: "All", comment: "Inventory filter: show all spools")
        case .inAMS: String(localized: "In AMS", comment: "Inventory filter: spools currently loaded in an AMS")
        case .inStorage: String(localized: "In Storage", comment: "Inventory filter: spools not loaded in an AMS")
        case .pla: FilamentMaterial.pla.rawValue
        case .petg: FilamentMaterial.petg.rawValue
        case .abs: FilamentMaterial.abs.rawValue
        case .tpu: FilamentMaterial.tpu.rawValue
        }
    }
}

enum InventoryLayout {
    case grid, list
}

struct InventoryView: View {
    @Environment(AppStore.self) private var store
    @State private var filter: InventoryFilter = .all
    @State private var searchText = ""
    @State private var layout: InventoryLayout = .grid
    @State private var editingSpool: Spool?
    @Binding var selectedTab: RootTab

    /// Recomputed via `onChange`/`onAppear` below rather than as a computed property, so
    /// filtering/searching over `store.spools` only runs when an actual input changed, not on
    /// every unrelated body evaluation of this view.
    @State private var filtered: [Spool] = []

    private func recomputeFiltered() {
        filtered = store.spools.filter { spool in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .inAMS: if case .ams = spool.location { matchesFilter = true } else { matchesFilter = false }
            case .inStorage: if case .storage = spool.location { matchesFilter = true } else { matchesFilter = false }
            case .pla: matchesFilter = spool.material.caseInsensitiveCompare(FilamentMaterial.pla.rawValue) == .orderedSame
            case .petg: matchesFilter = spool.material.caseInsensitiveCompare(FilamentMaterial.petg.rawValue) == .orderedSame
            case .abs: matchesFilter = spool.material.caseInsensitiveCompare(FilamentMaterial.abs.rawValue) == .orderedSame
            case .tpu: matchesFilter = spool.material.caseInsensitiveCompare(FilamentMaterial.tpu.rawValue) == .orderedSame
            }

            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesSearch = query.isEmpty
                || spool.colorName.localizedCaseInsensitiveContains(query)
                || spool.brand.localizedCaseInsensitiveContains(query)
                || spool.material.localizedCaseInsensitiveContains(query)

            return matchesFilter && matchesSearch
        }
    }

    private var totalGrams: Int {
        store.spools.reduce(0) { $0 + Int(Double($1.netWeightGrams) * Double($1.remainingPercent) / 100) }
    }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var isConnecting: Bool { store.isLoadingSpools }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Filament")
                                .ncFont(size: 34, weight: .bold, relativeTo: .largeTitle)
                            Group {
                                if isConnecting {
                                    Text("Connecting to Bambuddy…")
                                } else {
                                    Text("\(store.spools.count) spools · \(totalGrams) g on hand")
                                }
                            }
                            .ncFont(size: 15, relativeTo: .subheadline)
                            .foregroundStyle(NCColor.textSecondary)
                        }
                        .padding(.horizontal, 16)

                        if isConnecting {
                            VStack(spacing: 14) {
                                ProgressView().tint(NCColor.accentLight)
                                Text("Loading your inventory…")
                                    .ncFont(size: 13, relativeTo: .footnote)
                                    .foregroundStyle(NCColor.textTertiary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                        } else {
                            searchField
                                .padding(.horizontal, 16)

                            HStack(spacing: 8) {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(InventoryFilter.allCases, id: \.self) { f in
                                            FilterChip(title: f.title, isActive: filter == f) { filter = f }
                                        }
                                    }
                                }
                                layoutToggle
                            }
                            .padding(.horizontal, 16)

                            if filtered.isEmpty {
                                Group {
                                    if searchText.isEmpty {
                                        Text("No spools match this filter.")
                                    } else {
                                        Text("No spools match \"\(searchText)\".")
                                    }
                                }
                                .ncFont(size: 13, relativeTo: .footnote)
                                .foregroundStyle(NCColor.textTertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                            } else if layout == .grid {
                                LazyVGrid(columns: columns, spacing: 12) {
                                    ForEach(filtered) { spool in
                                        Button { editingSpool = spool } label: {
                                            SpoolCard(spool: spool)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.bottom, 100)
                            } else {
                                LazyVStack(spacing: 8) {
                                    ForEach(filtered) { spool in
                                        Button { editingSpool = spool } label: {
                                            SpoolListRow(spool: spool)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.bottom, 100)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                .background(NCColor.canvasBackground.ignoresSafeArea())
                .navigationBarHidden(true)
                .refreshable { await store.testConnectionAndRefresh() }

                Button {
                    selectedTab = .scan
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(NCColor.accent))
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                }
                .padding(.trailing, 20)
                .padding(.bottom, 96)
            }
            .sheet(item: $editingSpool) { spool in
                EditSpoolSheet(spool: spool)
            }
        }
        .onAppear { recomputeFiltered() }
        .onChange(of: store.spools) { recomputeFiltered() }
        .onChange(of: filter) { recomputeFiltered() }
        .onChange(of: searchText) { recomputeFiltered() }
    }

    private var layoutToggle: some View {
        Button {
            layout = layout == .grid ? .list : .grid
        } label: {
            Image(systemName: layout == .grid ? "list.bullet" : "square.grid.2x2")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(NCColor.textSecondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(layout == .grid ? Text("Switch to list view") : Text("Switch to grid view"))
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

struct SpoolCard: View {
    var spool: Spool
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                spool.swatch
                Text(spool.material)
                    .ncFont(size: 11, weight: .bold, relativeTo: .caption2)
                    .foregroundStyle(Color(hex: spool.colorHex).isLight ? .black.opacity(0.7) : .white)
                    .padding(8)
            }
            .frame(height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(spool.colorName)
                    .ncFont(size: 12.5, weight: .semibold, relativeTo: .caption)
                    .foregroundStyle(.white)
                Text(spool.brand)
                    .ncFont(size: 10.5, relativeTo: .caption2)
                    .foregroundStyle(NCColor.textTertiary)

                HStack(spacing: 6) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 3)
                        .overlay(alignment: .leading) {
                            GeometryReader { geo in
                                Capsule()
                                    .fill(Color(hex: spool.colorHex))
                                    .frame(width: geo.size.width * Double(spool.remainingPercent) / 100)
                            }
                        }
                    Text(Double(spool.remainingPercent) / 100, format: .percent.precision(.fractionLength(0)))
                        .ncFont(size: 9.5, weight: .semibold, relativeTo: .caption2)
                        .foregroundStyle(NCColor.textSecondary)
                        .fixedSize()
                }
                .padding(.top, 2)

                Text(spool.locationCaption(printerName: store.printerName))
                    .ncFont(size: 10.5, relativeTo: .caption2)
                    .foregroundStyle(NCColor.textTertiary)
                    .padding(.top, 2)
            }
        }
        .padding(10)
        .glassCard(cornerRadius: 16)
    }
}

struct SpoolListRow: View {
    var spool: Spool
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            spool.swatch
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    Text(spool.material)
                        .ncFont(size: 9, weight: .bold, relativeTo: .caption2)
                        .foregroundStyle(Color(hex: spool.colorHex).isLight ? .black.opacity(0.7) : .white)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(spool.colorName)
                    .ncFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                    .foregroundStyle(.white)
                Text("\(spool.brand) · \(spool.locationCaption(printerName: store.printerName))")
                    .ncFont(size: 11.5, relativeTo: .caption)
                    .foregroundStyle(NCColor.textTertiary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 3)
                        .overlay(alignment: .leading) {
                            GeometryReader { geo in
                                Capsule()
                                    .fill(Color(hex: spool.colorHex))
                                    .frame(width: geo.size.width * Double(spool.remainingPercent) / 100)
                            }
                        }
                    Text(Double(spool.remainingPercent) / 100, format: .percent.precision(.fractionLength(0)))
                        .ncFont(size: 10.5, weight: .semibold, relativeTo: .caption2)
                        .foregroundStyle(NCColor.textSecondary)
                        .fixedSize()
                }
                .padding(.top, 2)
            }

            Spacer()
        }
        .padding(10)
        .glassCard(cornerRadius: 14)
    }
}

#Preview {
    InventoryView(selectedTab: .constant(.inventory))
        .environment(AppStore(config: BambuddyConfig()))
        .preferredColorScheme(.dark)
}
