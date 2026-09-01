import Foundation

/// Open Filament Database (openfilamentdatabase.org) barcode lookup — ~2,500 real spool
/// GTINs joined to brand/material/colour/weight. Downloads the public data dump once,
/// builds a barcode -> fields index on-device, and caches it with a 24h TTL. Ported from
/// filament_to_bambuddy's `ofd.py`.
final class OFDClient {
    static let shared = OFDClient()

    private struct RawBrand: Decodable { var id: String; var name: String? }
    private struct RawFilament: Decodable {
        var id: String
        var name: String?
        var brand_id: String?
        var material: String?
        var min_print_temperature: Int?
        var max_print_temperature: Int?
    }
    private struct RawVariant: Decodable {
        var id: String
        var name: String?
        var color_hex: String?
        var filament_id: String?
    }
    private struct RawSize: Decodable {
        var gtin: String?
        var article_number: String?
        var variant_id: String?
        var filament_weight: Double?
        var spool_refill: Bool?
    }
    private struct AllJSON: Decodable {
        var brands: [RawBrand]
        var filaments: [RawFilament]
        var variants: [RawVariant]
        var sizes: [RawSize]
    }

    private struct IndexEntry: Codable { var fields: FilamentDBFields; var variantId: String }
    private struct Cache: Codable {
        var version: Int
        var builtAt: Date
        var gtinIndex: [String: IndexEntry]
        var articleIndex: [String: IndexEntry]
        var variantCodes: [String: [FilamentCodeEntry]]
        var brands: [String]
    }

    private static let allURL = URL(string: "https://api.openfilamentdatabase.org/json/all.json")!
    private static let ttl: TimeInterval = 24 * 3600
    private static let cacheVersion = 1

    private var cache: Cache?
    private var loadTask: Task<Cache, Error>?

    private var cacheFileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ofd_index.json")
    }

    func brands() async -> [String] {
        (try? await ensureLoaded())?.brands ?? []
    }

    func lookup(gtin: String) async -> (fields: FilamentDBFields, siblingCodes: [FilamentCodeEntry])? {
        guard let cache = try? await ensureLoaded(), let entry = cache.gtinIndex[FilamentCode.canon(gtin)] else { return nil }
        return (entry.fields, cache.variantCodes[entry.variantId] ?? [])
    }

    func lookupArticle(_ code: String) async -> (fields: FilamentDBFields, siblingCodes: [FilamentCodeEntry])? {
        guard let cache = try? await ensureLoaded(), let entry = cache.articleIndex[code.trimmingCharacters(in: .whitespaces).uppercased()] else { return nil }
        return (entry.fields, cache.variantCodes[entry.variantId] ?? [])
    }

    private func ensureLoaded() async throws -> Cache {
        if let cache, Date().timeIntervalSince(cache.builtAt) < Self.ttl { return cache }
        if let loadTask { return try await loadTask.value }

        let task = Task<Cache, Error> {
            if let onDisk = readDiskCache(), Date().timeIntervalSince(onDisk.builtAt) < Self.ttl {
                return onDisk
            }
            do {
                let fresh = try await refresh()
                return fresh
            } catch {
                if let stale = readDiskCache() { return stale }
                throw error
            }
        }
        loadTask = task
        let result = try await task.value
        cache = result
        loadTask = nil
        return result
    }

    private func readDiskCache() -> Cache? {
        guard let data = try? Data(contentsOf: cacheFileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let decoded = try? decoder.decode(Cache.self, from: data), decoded.version == Self.cacheVersion else { return nil }
        return decoded
    }

    private func writeDiskCache(_ cache: Cache) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(cache) else { return }
        try? data.write(to: cacheFileURL, options: .atomic)
    }

    private func refresh() async throws -> Cache {
        let (data, _) = try await URLSession.shared.data(from: Self.allURL)
        let all = try JSONDecoder().decode(AllJSON.self, from: data)

        let brandsByID = Dictionary(uniqueKeysWithValues: all.brands.map { ($0.id, $0) })
        let filamentsByID = Dictionary(uniqueKeysWithValues: all.filaments.map { ($0.id, $0) })
        let variantsByID = Dictionary(uniqueKeysWithValues: all.variants.map { ($0.id, $0) })

        var gtinIndex: [String: IndexEntry] = [:]
        var articleIndex: [String: IndexEntry] = [:]
        var variantCodes: [String: [FilamentCodeEntry]] = [:]

        for size in all.sizes {
            guard size.gtin != nil || size.article_number != nil, let variantID = size.variant_id,
                  let variant = variantsByID[variantID], let filamentID = variant.filament_id,
                  let filament = filamentsByID[filamentID] else { continue }

            let material = filament.material ?? ""
            let brandName = filament.brand_id.flatMap { brandsByID[$0]?.name }
            let subtype = Self.subtype(from: filament.name ?? "", material: material)
            let rgba = Self.hexToRGBA(variant.color_hex)

            var fields = FilamentDBFields()
            if !material.isEmpty { fields.material = material }
            fields.brand = brandName
            fields.subtype = subtype
            fields.colorName = variant.name
            fields.rgba = rgba
            if let weight = size.filament_weight { fields.labelWeight = Int(weight.rounded()) }
            fields.nozzleTempMin = filament.min_print_temperature
            fields.nozzleTempMax = filament.max_print_temperature
            fields.title = [brandName, filament.name, variant.name].compactMap { $0 }.joined(separator: " ")

            let isRefill = size.spool_refill ?? false
            var codes = variantCodes[variantID] ?? []

            if let gtin = size.gtin {
                let canonical = FilamentCode.canon(gtin)
                gtinIndex[canonical] = IndexEntry(fields: fields, variantId: variantID)
                if !codes.contains(where: { $0.code == canonical }) {
                    codes.append(FilamentCodeEntry(code: canonical, kind: "gtin", isRefill: isRefill))
                }
            }
            if let article = size.article_number {
                let normalized = article.trimmingCharacters(in: .whitespaces).uppercased()
                articleIndex[normalized] = IndexEntry(fields: fields, variantId: variantID)
                if !codes.contains(where: { $0.code == normalized }) {
                    codes.append(FilamentCodeEntry(code: normalized, kind: "sku", isRefill: isRefill))
                }
            }
            variantCodes[variantID] = codes
        }

        let brandNames = Set(all.brands.compactMap(\.name)).sorted()
        let fresh = Cache(version: Self.cacheVersion, builtAt: Date(), gtinIndex: gtinIndex, articleIndex: articleIndex, variantCodes: variantCodes, brands: brandNames)
        writeDiskCache(fresh)
        return fresh
    }

    private static func subtype(from filamentName: String, material: String) -> String? {
        var s = filamentName
        if !material.isEmpty {
            s = s.replacingOccurrences(of: material, with: "", options: [.caseInsensitive, .regularExpression])
        }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -+"))
        return s.isEmpty ? nil : s
    }

    private static func hexToRGBA(_ hex: String?) -> String? {
        guard var h = hex else { return nil }
        h = h.hasPrefix("#") ? String(h.dropFirst()) : h
        guard h.count == 6, h.range(of: "^[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else { return nil }
        return h.uppercased() + "FF"
    }
}
