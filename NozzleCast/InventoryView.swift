import SwiftUI

enum InventoryFilter: Hashable, CaseIterable {
    case all, inAMS, inStorage, pla, petg, abs, tpu

    var title: String {
        switch self {
        case .all: "All"
        case .inAMS: "In AMS"
        case .inStorage: "In Storage"
        case .pla: "PLA"
        case .petg: "PETG"
        case .abs: "ABS"
        case .tpu: "TPU"
        }
    }
}

struct InventoryView: View {
    @Environment(AppStore.self) private var store
    @State private var filter: InventoryFilter = .all
    @State private var searchText = ""
    @Binding var selectedTab: RootTab

    private var filtered: [Spool] {
        store.spools.filter { spool in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .inAMS: if case .ams = spool.location { matchesFilter = true } else { matchesFilter = false }
            case .inStorage: if case .storage = spool.location { matchesFilter = true } else { matchesFilter = false }
            case .pla: matchesFilter = spool.material == .pla
            case .petg: matchesFilter = spool.material == .petg
            case .abs: matchesFilter = spool.material == .abs
            case .tpu: matchesFilter = spool.material == .tpu
            }

            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesSearch = query.isEmpty
                || spool.colorName.localizedCaseInsensitiveContains(query)
                || spool.brand.localizedCaseInsensitiveContains(query)
                || spool.material.rawValue.localizedCaseInsensitiveContains(query)

            return matchesFilter && matchesSearch
        }
    }

    private var totalGrams: Int {
        store.spools.reduce(0) { $0 + Int(Double($1.netWeightGrams) * Double($1.remainingPercent) / 100) }
    }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var isConnecting: Bool {
        if case .connecting = store.connectionStatus, store.spools.isEmpty { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Filament")
                                .font(.system(size: 34, weight: .bold))
                            Text(isConnecting ? "Connecting to Bambuddy…" : "\(store.spools.count) spools · \(totalGrams) g on hand")
                                .font(.system(size: 15))
                                .foregroundStyle(NCColor.textSecondary)
                        }
                        .padding(.horizontal, 16)

                        if isConnecting {
                            VStack(spacing: 14) {
                                ProgressView().tint(NCColor.accentLight)
                                Text("Loading your inventory…")
                                    .font(.system(size: 13))
                                    .foregroundStyle(NCColor.textTertiary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                        } else {
                            searchField
                                .padding(.horizontal, 16)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(InventoryFilter.allCases, id: \.self) { f in
                                        FilterChip(title: f.title, isActive: filter == f) { filter = f }
                                    }
                                }
                                .padding(.horizontal, 16)
                            }

                            if filtered.isEmpty {
                                Text(searchText.isEmpty ? "No spools match this filter." : "No spools match \"\(searchText)\".")
                                    .font(.system(size: 13))
                                    .foregroundStyle(NCColor.textTertiary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 40)
                            } else {
                                LazyVGrid(columns: columns, spacing: 12) {
                                    ForEach(filtered) { spool in
                                        SpoolCard(spool: spool)
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
                .refreshable { await store.refresh() }

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
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(NCColor.textTertiary)
            TextField("Search filament", text: $searchText)
                .font(.system(size: 15))
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
                Color(hex: spool.colorHex)
                Text(spool.material.rawValue)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(hex: spool.colorHex).isLight ? .black.opacity(0.7) : .white)
                    .padding(8)
            }
            .frame(height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(spool.colorName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(spool.brand)
                    .font(.system(size: 10.5))
                    .foregroundStyle(NCColor.textTertiary)

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
                    .padding(.top, 2)

                Text(spool.locationCaption(printerName: store.printerName))
                    .font(.system(size: 10.5))
                    .foregroundStyle(NCColor.textTertiary)
                    .padding(.top, 2)
            }
        }
        .padding(10)
        .glassCard(cornerRadius: 16)
    }
}
