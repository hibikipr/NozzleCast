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
    @Binding var selectedTab: RootTab

    private var filtered: [Spool] {
        store.spools.filter { spool in
            switch filter {
            case .all: true
            case .inAMS: if case .ams = spool.location { true } else { false }
            case .inStorage: if case .storage = spool.location { true } else { false }
            case .pla: spool.material == .pla
            case .petg: spool.material == .petg
            case .abs: spool.material == .abs
            case .tpu: spool.material == .tpu
            }
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
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(InventoryFilter.allCases, id: \.self) { f in
                                        FilterChip(title: f.title, isActive: filter == f) { filter = f }
                                    }
                                }
                                .padding(.horizontal, 16)
                            }

                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(filtered) { spool in
                                    SpoolCard(spool: spool)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 100)
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
