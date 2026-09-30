import SwiftUI

enum InventoryFilter: Hashable, CaseIterable {
    /// `archived` is last and, unlike the rest, lists `AppStore.archivedSpools` rather than a
    /// subset of the active inventory.
    case all, inAMS, inStorage, pla, petg, abs, tpu, archived

    var title: String {
        switch self {
        case .all: String(localized: "All", comment: "Inventory filter: show all spools")
        case .inAMS: String(localized: "In AMS", comment: "Inventory filter: spools currently loaded in an AMS")
        case .inStorage: String(localized: "In Storage", comment: "Inventory filter: spools not loaded in an AMS")
        case .pla: FilamentMaterial.pla.rawValue
        case .petg: FilamentMaterial.petg.rawValue
        case .abs: FilamentMaterial.abs.rawValue
        case .tpu: FilamentMaterial.tpu.rawValue
        case .archived: String(localized: "Archived", comment: "Inventory filter: spools that have been archived")
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
    /// Set by a card's "Delete…" menu item; drives the confirmation dialog. Deleting is permanent,
    /// so it never happens straight from the menu tap.
    @State private var spoolPendingDeletion: Spool?
    @Binding var selectedTab: RootTab

    /// Recomputed via `onChange`/`onAppear` below rather than as a computed property, so
    /// filtering/searching over `store.spools` only runs when an actual input changed, not on
    /// every unrelated body evaluation of this view.
    @State private var filtered: [Spool] = []

    private func recomputeFiltered() {
        let source = filter == .archived ? store.archivedSpools : store.spools
        filtered = source.filter { spool in
            let matchesFilter: Bool
            switch filter {
            case .all, .archived: matchesFilter = true
            case .inAMS: if case .ams = spool.location { matchesFilter = true } else { matchesFilter = false }
            case .inStorage: if case .storage = spool.location { matchesFilter = true } else { matchesFilter = false }
            case .pla: matchesFilter = Self.material(spool.material, isIn: .pla)
            case .petg: matchesFilter = Self.material(spool.material, isIn: .petg)
            case .abs: matchesFilter = Self.material(spool.material, isIn: .abs)
            case .tpu: matchesFilter = Self.material(spool.material, isIn: .tpu)
            }

            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesSearch = query.isEmpty
                || spool.colorName.localizedCaseInsensitiveContains(query)
                || spool.brand.localizedCaseInsensitiveContains(query)
                || spool.material.localizedCaseInsensitiveContains(query)

            return matchesFilter && matchesSearch
        }
    }

    /// Whether a spool's free-form material belongs to a filter's material family: its first
    /// word, split on spaces and hyphens, must be the family name. Bambuddy stores variants as
    /// their own material strings — "TPU for AMS", "PLA-CF", "PETG-HF" — and the filters used to
    /// require an exact "TPU", silently leaving those out. Matching the first word rather than
    /// "contains" keeps "Support for PLA" (a support material) out of the PLA filter.
    static func material(_ material: String, isIn family: FilamentMaterial) -> Bool {
        guard let first = material.split(whereSeparator: { $0 == " " || $0 == "-" }).first else { return false }
        return first.caseInsensitiveCompare(family.rawValue) == .orderedSame
    }

    private static func gramsOnHand(_ spools: [Spool]) -> Int {
        spools.reduce(0) { $0 + Int(Double($1.netWeightGrams) * Double($1.remainingPercent) / 100) }
    }

    /// The line under "Filament", describing what's actually on screen rather than the whole
    /// inventory: it used to say "59 spools" even while showing the Archived filter or a search.
    /// When only part of a list is shown it says so ("12 of 59 spools"), and grams only apply to
    /// active spools — archived ones aren't on hand. Inflection handles "1 spool" vs "2 spools".
    @ViewBuilder
    private var headerSummary: some View {
        let grams = Self.gramsOnHand(filtered)
        let isNarrowed = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if filter == .archived {
            let total = store.archivedSpools.count
            if isNarrowed {
                Text("\(filtered.count) of ^[\(total) archived spool](inflect: true)", comment: "Inventory header: archived spools matching a search, e.g. '3 of 10 archived spools'")
            } else {
                Text("^[\(total) archived spool](inflect: true)", comment: "Inventory header: number of archived spools")
            }
        } else if filter != .all || isNarrowed {
            Text("\(filtered.count) of ^[\(store.spools.count) spool](inflect: true) · \(grams) g on hand", comment: "Inventory header when a filter or search is active, e.g. '12 of 59 spools · 6200 g on hand'")
        } else {
            Text("^[\(store.spools.count) spool](inflect: true) · \(grams) g on hand", comment: "Inventory header: all active spools and their remaining weight")
        }
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
                                    Text("Connecting to server…")
                                } else {
                                    headerSummary
                                }
                            }
                            .ncFont(size: 15, relativeTo: .subheadline)
                            .foregroundStyle(NCColor.textSecondary)
                        }
                        .padding(.horizontal, 16)

                        if store.isShowingDemoData {
                            DemoDataBanner(connectionStatus: store.connectionStatus) { selectedTab = .settings }
                                .padding(.horizontal, 16)
                        } else if let message = store.serverUnreachableMessage {
                            ServerUnreachableBanner(message: message) { selectedTab = .settings }
                                .padding(.horizontal, 16)
                        }

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

                            if filter == .archived && !filtered.isEmpty {
                                Text("Long-press a spool to restore it or delete it for good.", comment: "Hint above the archived spools list")
                                    .ncFont(size: 12, relativeTo: .caption)
                                    .foregroundStyle(NCColor.textTertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16)
                            }

                            if filtered.isEmpty {
                                Group {
                                    if filter == .archived && searchText.isEmpty {
                                        Text("No archived spools.", comment: "Empty state of the Archived inventory filter")
                                    } else if searchText.isEmpty {
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
                                        Button { edit(spool) } label: {
                                            SpoolCard(spool: spool)
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu { spoolActions(spool) }
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.bottom, 100)
                            } else {
                                LazyVStack(spacing: 8) {
                                    ForEach(filtered) { spool in
                                        Button { edit(spool) } label: {
                                            SpoolListRow(spool: spool)
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu { spoolActions(spool) }
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
            .overlay(alignment: .bottomLeading) {
                if let archived = store.recentlyArchivedSpool {
                    ArchivedSpoolUndoBar(spool: archived) { store.restoreArchivedSpool() }
                        .padding(.leading, 16)
                        .padding(.trailing, 88) // clear of the floating add button
                        .padding(.bottom, 100)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: store.recentlyArchivedSpool?.id)
            // The Undo bar is only offered briefly; the archive itself already happened.
            .task(id: store.recentlyArchivedSpool?.id) {
                guard let id = store.recentlyArchivedSpool?.id else { return }
                try? await Task.sleep(for: .seconds(8))
                if store.recentlyArchivedSpool?.id == id { store.recentlyArchivedSpool = nil }
            }
            .sheet(item: $editingSpool) { spool in
                EditSpoolSheet(spool: spool)
            }
            .confirmationDialog(
                Text("Delete this spool?", comment: "Delete spool confirmation title"),
                isPresented: Binding(
                    get: { spoolPendingDeletion != nil },
                    set: { if !$0 { spoolPendingDeletion = nil } }
                ),
                titleVisibility: .visible,
                presenting: spoolPendingDeletion
            ) { spool in
                Button(role: .destructive) {
                    store.deleteSpool(spool.id)
                } label: {
                    Text("Delete Permanently", comment: "Delete spool confirmation button")
                }
                Button(role: .cancel) {} label: { Text("Cancel") }
            } message: { spool in
                // Suggesting "archive it instead" only makes sense for a spool that isn't already.
                if store.archivedSpool(spool.id) != nil {
                    Text("\(spool.brand) \(spool.material) \(spool.colorName) will be removed for good, including its usage history.", comment: "Delete confirmation message for an already-archived spool")
                } else {
                    Text("\(spool.brand) \(spool.material) \(spool.colorName) will be removed from your inventory for good, including its usage history. Archive it instead to keep the record.", comment: "Delete spool confirmation message")
                }
            }
        }
        .onAppear { recomputeFiltered() }
        .onChange(of: store.spools) { recomputeFiltered() }
        .onChange(of: store.archivedSpools) { recomputeFiltered() }
        .onChange(of: filter) { recomputeFiltered() }
        .onChange(of: searchText) { recomputeFiltered() }
    }

    /// Long-press actions on a spool card or row. Archive is the everyday "done with this spool"
    /// action (reversible from the Undo bar); Delete is permanent and always confirms first.
    @ViewBuilder
    private func spoolActions(_ spool: Spool) -> some View {
        if store.archivedSpool(spool.id) != nil {
            Button { store.restoreSpool(spool.id) } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
        } else {
            Button { editingSpool = spool } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button { store.archiveSpool(spool.id) } label: {
                Label("Archive", systemImage: "archivebox")
            }
        }
        Button(role: .destructive) { spoolPendingDeletion = spool } label: {
            Label("Delete…", systemImage: "trash")
        }
    }

    /// Opens the editor for an active spool. Archived spools aren't editable (Bambuddy's own UI
    /// doesn't offer it either); their actions live in the long-press menu instead.
    private func edit(_ spool: Spool) {
        guard store.archivedSpool(spool.id) == nil else { return }
        editingSpool = spool
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
            ZStack(alignment: .top) {
                spool.swatch
                colorNamePill
                    .padding(.top, 8)
                    .padding(.horizontal, 8)
            }
            .frame(height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(dimming)
            .overlay(alignment: .bottomTrailing) {
                if spool.isArchived { ArchivedBadge().padding(6) }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(spool.materialWithEffect)
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

                Text(spool.locationCaption(printerName: store.printerName, amsUnitName: store.amsUnitName))
                    .ncFont(size: 10.5, relativeTo: .caption2)
                    .foregroundStyle(NCColor.textTertiary)
                    .padding(.top, 2)
            }
            .opacity(dimming)
        }
        .padding(10)
        .glassCard(cornerRadius: 16)
    }

    /// An archived spool's swatch and text are dimmed so it reads as inactive, while the card
    /// outline and the archived badge stay at full strength.
    private var dimming: Double { spool.isArchived ? ArchivedBadge.contentOpacity : 1 }

    /// Bambuddy's own spool cards put the color name in a pill on the swatch itself, with
    /// material/subtype as the headline below — matching that here so the color's identity
    /// stays with its swatch instead of competing with material/subtype for the headline spot.
    private var colorNamePill: some View {
        Text(spool.colorName)
            .ncFont(size: 10.5, weight: .semibold, relativeTo: .caption2)
            .foregroundStyle(.black.opacity(0.75))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(0.92)))
            // Without this, a near-white spool (e.g. "Pure White") leaves the pill nearly
            // invisible against a same-toned swatch — this keeps it legible on every color.
            .overlay(Capsule().strokeBorder(Color.black.opacity(0.12), lineWidth: 1))
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
                .opacity(dimming)
                .overlay(alignment: .bottomTrailing) {
                    if spool.isArchived { ArchivedBadge(size: 16).offset(x: 4, y: 4) }
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(spool.materialWithEffect)
                    .ncFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                    .foregroundStyle(.white)
                Text("\(spool.colorName) · \(spool.brand) · \(spool.locationCaption(printerName: store.printerName, amsUnitName: store.amsUnitName))")
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
            .opacity(dimming)

            Spacer()
        }
        .padding(10)
        .glassCard(cornerRadius: 14)
    }

    private var dimming: Double { spool.isArchived ? ArchivedBadge.contentOpacity : 1 }
}

/// Small archive-box marker on an archived spool's swatch, so the card says "archived" on its
/// own — not only through the Archived filter it happens to be listed under.
private struct ArchivedBadge: View {
    var size: CGFloat = 20

    /// How far an archived spool's card contents are dimmed.
    static let contentOpacity = 0.55

    var body: some View {
        Image(systemName: "archivebox.fill")
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.black.opacity(0.7)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            .accessibilityLabel(Text("Archived", comment: "Accessibility label for the archived spool badge"))
    }
}

#Preview {
    InventoryView(selectedTab: .constant(.inventory))
        .environment(AppStore(config: BambuddyConfig()))
        .preferredColorScheme(.dark)
}

/// Brief confirmation after archiving a spool, with the only way back: archived spools are hidden
/// everywhere in the app, so without Undo a mis-tap would mean a trip to Bambuddy's web UI.
private struct ArchivedSpoolUndoBar: View {
    var spool: Spool
    var undo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox.fill")
                .foregroundStyle(NCColor.textSecondary)
            Text("Archived \(spool.colorName) \(spool.material)", comment: "Undo bar after archiving a spool, e.g. 'Archived Jade White PLA'")
                .ncFont(size: 14, weight: .medium, relativeTo: .subheadline)
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: undo) {
                Text("Undo", comment: "Undo archiving a spool")
                    .ncFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                    .foregroundStyle(NCColor.accentLight)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Capsule().fill(Color(hex: "#2C2C2E")))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text("Undo")) { undo() }
    }
}
