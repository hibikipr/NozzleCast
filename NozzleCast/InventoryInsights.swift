import Foundation

/// Where a spool can be bought, from Bambuddy's supplier records.
struct SpoolSupplier: Equatable, Hashable {
    var name: String
    var articleNumber: String?
    var pricePerKg: Double?
    /// The supplier this spool was actually bought from, as opposed to another place that sells it.
    var isPurchaseSource: Bool
}

/// One print's draw on a spool.
struct SpoolUsageRecord: Identifiable, Equatable {
    var id: Int
    var printName: String
    var printerName: String?
    var grams: Double
    var cost: Double?
    var date: Date?
    var outcome: PrintRecord.Outcome
}

/// A filament to buy, on Bambuddy's shopping list. Describes a SKU (material, brand, color), not
/// a particular spool — buying it means adding a new spool.
struct ShoppingListItem: Identifiable, Equatable {
    enum Status: String, CaseIterable {
        case pending, purchased, received

        var title: String {
            switch self {
            case .pending: String(localized: "To Buy", comment: "Shopping list status: not bought yet")
            case .purchased: String(localized: "Ordered", comment: "Shopping list status: bought, not arrived")
            case .received: String(localized: "Received", comment: "Shopping list status: arrived")
            }
        }
    }

    var id: String
    var bambuddyID: Int
    var material: String
    var subtype: String?
    var brand: String?
    var colorName: String?
    var quantity: Int
    var note: String?
    var status: Status
    var addedAt: Date?

    /// "Bambu Lab PLA Basic · Jade White"
    var title: String {
        let product = [brand, subtype.flatMap { $0.range(of: material, options: .caseInsensitive) != nil ? $0 : "\(material) \($0)" } ?? material]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " ")
        guard let colorName, !colorName.isEmpty else { return product }
        return "\(product) · \(colorName)"
    }

    /// Whether this entry is for the same filament as `spool` — same material, brand, subtype and
    /// color name, ignoring case. What keeps "Add to Shopping List" from adding a duplicate.
    func describes(_ spool: Spool) -> Bool {
        func same(_ a: String?, _ b: String?) -> Bool {
            (a ?? "").trimmingCharacters(in: .whitespaces).caseInsensitiveCompare((b ?? "").trimmingCharacters(in: .whitespaces)) == .orderedSame
        }
        // The app shows a spool with no brand as "Unknown"; Bambuddy stores no brand at all.
        let spoolBrand = spool.brand == "Unknown" ? nil : spool.brand
        return same(material, spool.material) && same(brand, spoolBrand) && same(subtype, spool.subtype) && same(colorName, spool.colorName)
    }
}
