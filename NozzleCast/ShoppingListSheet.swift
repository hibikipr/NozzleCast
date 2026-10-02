import SwiftUI

/// Bambuddy's filament shopping list, plus the low-stock spools that aren't on it yet.
struct ShoppingListSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Low-stock spools whose filament isn't on the list yet, one per filament — three
    /// near-empty spools of the same PLA are one thing to buy.
    private var lowStockSuggestions: [Spool] {
        var seen: [Spool] = []
        for spool in store.lowStockSpools.sorted(by: { $0.remainingPercent < $1.remainingPercent })
        where store.shoppingListItem(for: spool) == nil && !seen.contains(where: { Self.sameFilament($0, spool) }) {
            seen.append(spool)
        }
        return seen
    }

    private static func sameFilament(_ a: Spool, _ b: Spool) -> Bool {
        a.material.caseInsensitiveCompare(b.material) == .orderedSame
            && a.brand.caseInsensitiveCompare(b.brand) == .orderedSame
            && (a.subtype ?? "").caseInsensitiveCompare(b.subtype ?? "") == .orderedSame
            && a.colorName.caseInsensitiveCompare(b.colorName) == .orderedSame
    }

    var body: some View {
        NavigationStack {
            List {
                if !lowStockSuggestions.isEmpty {
                    Section {
                        ForEach(lowStockSuggestions) { spool in
                            LowStockSuggestionRow(spool: spool) { store.addToShoppingList(spool) }
                        }
                    } header: {
                        Text("Running Low", comment: "Shopping list section: low-stock spools not on the list")
                    } footer: {
                        Text("Spools below their low-stock level in Bambuddy.", comment: "Shopping list footer under the low-stock suggestions")
                    }
                }

                ForEach(ShoppingListItem.Status.allCases, id: \.self) { status in
                    let items = store.shoppingList.filter { $0.status == status }
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { item in
                                ShoppingListRow(item: item)
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) { store.removeFromShoppingList(item.id) } label: {
                                            Label("Remove", systemImage: "trash")
                                        }
                                    }
                                    .swipeActions(edge: .leading) {
                                        if let next = status.next {
                                            Button { store.setShoppingListStatus(item.id, to: next) } label: {
                                                Label(next.actionTitle, systemImage: next.symbol)
                                            }
                                            .tint(NCColor.accent)
                                        }
                                    }
                            }
                        } header: {
                            Text(status.title)
                        }
                    }
                }

                if store.shoppingList.isEmpty && lowStockSuggestions.isEmpty {
                    Section {
                        Text("Nothing to buy. Long-press a spool in your inventory to add its filament here.", comment: "Empty shopping list")
                            .ncFont(size: 13, relativeTo: .footnote)
                            .foregroundStyle(NCColor.textTertiary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(hex: "#212121").ignoresSafeArea())
            .navigationTitle(Text("Shopping List", comment: "Shopping list sheet title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable { await store.loadShoppingList() }
            .task { await store.loadShoppingList() }
        }
        .preferredColorScheme(.dark)
    }
}

private extension ShoppingListItem.Status {
    /// The status a swipe moves an item on to: to buy → ordered → received.
    var next: Self? {
        switch self {
        case .pending: .purchased
        case .purchased: .received
        case .received: nil
        }
    }

    var actionTitle: String {
        switch self {
        case .pending: String(localized: "To Buy", comment: "Move a shopping list item back to 'to buy'")
        case .purchased: String(localized: "Ordered", comment: "Mark a shopping list item as ordered")
        case .received: String(localized: "Received", comment: "Mark a shopping list item as received")
        }
    }

    var symbol: String {
        switch self {
        case .pending: "cart"
        case .purchased: "shippingbox"
        case .received: "checkmark.circle"
        }
    }
}

private struct ShoppingListRow: View {
    var item: ShoppingListItem
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .ncFont(size: 15, weight: .medium, relativeTo: .subheadline)
                    .foregroundStyle(.white)
                Group {
                    if let addedAt = item.addedAt {
                        Text("Added \(addedAt.formatted(.relative(presentation: .named)))", comment: "When a shopping list item was added")
                    }
                    if let note = item.note, !note.isEmpty {
                        Text(note)
                    }
                }
                .ncFont(size: 12, relativeTo: .caption)
                .foregroundStyle(NCColor.textTertiary)
            }
            Spacer(minLength: 8)
            if item.quantity > 1 {
                Text("×\(item.quantity)", comment: "Number of spools to buy")
                    .ncFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                    .foregroundStyle(NCColor.textSecondary)
            }
            Menu {
                ForEach(ShoppingListItem.Status.allCases, id: \.self) { status in
                    Button { store.setShoppingListStatus(item.id, to: status) } label: {
                        if status == item.status {
                            Label(status.title, systemImage: "checkmark")
                        } else {
                            Text(status.title)
                        }
                    }
                }
                Divider()
                Button(role: .destructive) { store.removeFromShoppingList(item.id) } label: {
                    Label("Remove", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(NCColor.textSecondary)
            }
            .accessibilityLabel(Text("Change status", comment: "Shopping list item actions menu"))
        }
        .listRowBackground(Color.white.opacity(0.05))
    }
}

private struct LowStockSuggestionRow: View {
    var spool: Spool
    var add: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            spool.swatch
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(spool.brand) \(spool.materialWithEffect)")
                    .ncFont(size: 14, weight: .medium, relativeTo: .subheadline)
                    .foregroundStyle(.white)
                Text("\(spool.colorName) · \(spool.remainingGrams) g left", comment: "Low-stock spool: color and grams remaining")
                    .ncFont(size: 12, relativeTo: .caption)
                    .foregroundStyle(NCColor.statusWarning)
            }
            Spacer(minLength: 8)
            Button(action: add) {
                Label("Add", systemImage: "plus")
                    .ncFont(size: 13, weight: .semibold, relativeTo: .footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(NCColor.accent))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .listRowBackground(Color.white.opacity(0.05))
    }
}
