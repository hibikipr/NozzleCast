import Foundation

/// SpoolmanDB-Community (github.com/Icezaza2543/SpoolmanDB-Community) filament database —
/// broader brand/colour catalog than OFD, with sparser barcode coverage, so it's consulted
/// as a fallback after OFD. filament_to_bambuddy's `spoolmandb_community.py` parses the raw
/// per-manufacturer source files out of a repo tarball (to recover an exact `color.name`);
/// Foundation has no tar/gzip support without adding a dependency, so this instead uses
/// their compiled `filaments.json` (a flat array with `eans`/`eans_refill`/`codes` intact,
/// just without a separately-broken-out colour name — recovered here the same way OFD
/// recovers a subtype, by stripping the material word out of `name`).
final class SpoolmanDBCommunityClient {
    static let shared = SpoolmanDBCommunityClient()

    private struct RawEntry: Decodable {
        var manufacturer: String?
        var name: String?
        var material: String?
        var weight: Double?
        var color_hex: String?
        var extruder_temp: Int?
        var extruder_temp_range: [Int]?
        var codes: [String]?
        var eans: [String]?
        var eans_refill: [String]?
    }

    private struct IndexEntry: Codable { var fields: FilamentDBFields; var allCodes: [FilamentCodeEntry] }
    private struct Cache: Codable {
        var version: Int
        var builtAt: Date
        var gtinIndex: [String: IndexEntry]
        var skuIndex: [String: IndexEntry]
        var brands: [String]
    }

    private static let compiledURL = URL(string: "https://icezaza2543.github.io/SpoolmanDB-Community/filaments.json")!
    private static let ttl: TimeInterval = 24 * 3600
    private static let cacheVersion = 1

    private var cache: Cache?
    private var loadTask: Task<Cache, Error>?

    private var cacheFileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("smdb_community_index.json")
    }

    func brands() async -> [String] {
        (try? await ensureLoaded())?.brands ?? []
    }

    /// Throws only when the index itself couldn't be loaded (network/decode failure) - a
    /// non-throwing nil means the index loaded fine and the code just isn't in it. Callers
    /// must not collapse these two cases, or a failed download reads identically to "not
    /// found" with no way to tell the user which actually happened.
    func lookup(gtin: String) async throws -> (fields: FilamentDBFields, siblingCodes: [FilamentCodeEntry])? {
        let cache = try await ensureLoaded()
        guard let entry = cache.gtinIndex[FilamentCode.canon(gtin)] else { return nil }
        return (entry.fields, entry.allCodes)
    }

    func lookupSKU(_ code: String) async throws -> (fields: FilamentDBFields, siblingCodes: [FilamentCodeEntry])? {
        let cache = try await ensureLoaded()
        guard let entry = cache.skuIndex[code.trimmingCharacters(in: .whitespaces).uppercased()] else { return nil }
        return (entry.fields, entry.allCodes)
    }

    private func ensureLoaded() async throws -> Cache {
        if let cache, Date().timeIntervalSince(cache.builtAt) < Self.ttl { return cache }
        if let loadTask { return try await loadTask.value }

        let task = Task<Cache, Error> {
            if let onDisk = readDiskCache(), Date().timeIntervalSince(onDisk.builtAt) < Self.ttl {
                return onDisk
            }
            do {
                return try await refresh()
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
        let (data, _) = try await URLSession.shared.data(from: Self.compiledURL)
        let entries = try JSONDecoder().decode([RawEntry].self, from: data)

        var gtinIndex: [String: IndexEntry] = [:]
        var skuIndex: [String: IndexEntry] = [:]
        var brandSet = Set<String>()

        for entry in entries {
            guard let manufacturer = entry.manufacturer else { continue }
            brandSet.insert(manufacturer)

            let hasCodes = !(entry.eans?.isEmpty ?? true) || !(entry.eans_refill?.isEmpty ?? true) || !(entry.codes?.isEmpty ?? true)
            guard hasCodes else { continue }

            let material = entry.material ?? ""
            let colorName = Self.colorName(fromName: entry.name ?? "", material: material)
            var nozzleMin: Int?, nozzleMax: Int?
            if let range = entry.extruder_temp_range, range.count == 2 { nozzleMin = range[0]; nozzleMax = range[1] }
            else if let t = entry.extruder_temp { nozzleMin = t; nozzleMax = t }

            var fields = FilamentDBFields()
            fields.material = material.isEmpty ? nil : material
            fields.brand = manufacturer
            fields.colorName = colorName
            fields.rgba = Self.hexToRGBA(entry.color_hex)
            if let w = entry.weight { fields.labelWeight = Int(w.rounded()) }
            fields.nozzleTempMin = nozzleMin
            fields.nozzleTempMax = nozzleMax
            fields.title = [manufacturer, entry.name].compactMap { $0 }.joined(separator: " ")

            var allCodes: [FilamentCodeEntry] = []
            for ean in entry.eans ?? [] where !ean.trimmingCharacters(in: .whitespaces).isEmpty {
                allCodes.append(FilamentCodeEntry(code: FilamentCode.canon(ean), kind: "gtin", isRefill: false))
            }
            for ean in entry.eans_refill ?? [] where !ean.trimmingCharacters(in: .whitespaces).isEmpty {
                allCodes.append(FilamentCodeEntry(code: FilamentCode.canon(ean), kind: "gtin", isRefill: true))
            }
            for code in entry.codes ?? [] {
                let normalized = code.trimmingCharacters(in: .whitespaces).uppercased()
                if !normalized.isEmpty { allCodes.append(FilamentCodeEntry(code: normalized, kind: "sku", isRefill: false)) }
            }
            guard !allCodes.isEmpty else { continue }

            let indexEntry = IndexEntry(fields: fields, allCodes: allCodes)
            for codeEntry in allCodes {
                if codeEntry.kind == "gtin" { gtinIndex[codeEntry.code] = indexEntry }
                else { skuIndex[codeEntry.code] = indexEntry }
            }
        }

        let fresh = Cache(version: Self.cacheVersion, builtAt: Date(), gtinIndex: gtinIndex, skuIndex: skuIndex, brands: brandSet.sorted())
        writeDiskCache(fresh)
        return fresh
    }

    private static func colorName(fromName name: String, material: String) -> String? {
        var s = name
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
