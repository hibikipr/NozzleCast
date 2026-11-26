import Foundation

/// SpoolmanDB-Community (github.com/Icezaza2543/SpoolmanDB-Community) filament database —
/// broader brand/colour catalog than OFD, with sparser barcode coverage, so it's consulted
/// as a fallback after OFD. filament_to_bambuddy's `spoolmandb_community.py` parses the raw
/// per-manufacturer source files out of a repo tarball (to recover an exact `color.name`);
/// Foundation has no tar/gzip support without adding a dependency, so this instead uses
/// their compiled `filaments.json` (a flat array with `eans`/`eans_refill`/`codes` intact,
/// just without a separately-broken-out colour name — recovered here the same way OFD
/// recovers a subtype, by stripping the material word out of `name`).
actor SpoolmanDBCommunityClient {
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
        var diameter: Double?
        var color_hexes: [String]?
        var finish: String?
        var pattern: String?
        var multi_color_direction: String?
        var glow: Bool?
        var translucent: Bool?
    }

    private struct Cache: Codable {
        var version: Int
        var builtAt: Date
        var gtinIndex: [String: FilamentDBFields]
        var skuIndex: [String: FilamentDBFields]
        var brands: [String]
    }

    private static let compiledURL = URL(string: "https://icezaza2543.github.io/SpoolmanDB-Community/filaments.json")!
    private static let ttl: TimeInterval = 24 * 3600
    // 2: fields gained the effect and multicolour hexes. 3: a code shared by several sizes picks the likeliest. 4: dropped unused allCodes from disk cache.
    private static let cacheVersion = 4

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
        guard let fields = cache.gtinIndex[Self.canonicalGTIN(gtin)] else { return nil }
        return (fields, [])
    }

    func lookupSKU(_ code: String) async throws -> (fields: FilamentDBFields, siblingCodes: [FilamentCodeEntry])? {
        let cache = try await ensureLoaded()
        guard let fields = cache.skuIndex[code.trimmingCharacters(in: .whitespaces).uppercased()] else { return nil }
        return (fields, [])
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
        defer { if loadTask == task { loadTask = nil } }
        let result = try await task.value
        cache = result
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
        var request = URLRequest(url: Self.compiledURL)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let entries = try JSONDecoder().decode([RawEntry].self, from: data)

        var gtinIndex: [String: FilamentDBFields] = [:]
        var gtinRanks: [String: Int] = [:]
        var skuIndex: [String: FilamentDBFields] = [:]
        var skuRanks: [String: Int] = [:]
        var brandSet = Set<String>()

        for entry in entries {
            guard let manufacturer = entry.manufacturer else { continue }
            brandSet.insert(manufacturer)

            var gtins: [String] = []
            for ean in entry.eans ?? [] where !ean.trimmingCharacters(in: .whitespaces).isEmpty {
                gtins.append(Self.canonicalGTIN(ean))
            }
            for ean in entry.eans_refill ?? [] where !ean.trimmingCharacters(in: .whitespaces).isEmpty {
                gtins.append(Self.canonicalGTIN(ean))
            }
            var skus: [String] = []
            for code in entry.codes ?? [] {
                let normalized = code.trimmingCharacters(in: .whitespaces).uppercased()
                if !normalized.isEmpty { skus.append(normalized) }
            }
            guard !gtins.isEmpty || !skus.isEmpty else { continue }

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
            let hexes = (entry.color_hexes ?? []).compactMap(Self.hex6)
            fields.extraColorHexes = hexes.count >= 2 ? hexes : nil
            fields.effectType = Self.effect(
                finish: entry.finish, pattern: entry.pattern, multiColorDirection: entry.multi_color_direction,
                colorCount: hexes.count, glow: entry.glow ?? false, translucent: entry.translucent ?? false
            )

            // SpoolmanDB gives every size of a colour the same EAN and SKU (1, 3 and 5 kg, in 1.75
            // and 2.85 mm), so a code maps to several entries. Keep the likeliest box rather than
            // whichever came last: 1.75 mm first, then 1 kg.
            let rank = Self.sizeRank(diameter: entry.diameter, weight: entry.weight)
            for gtin in gtins {
                if (gtinRanks[gtin] ?? -1) < rank {
                    gtinRanks[gtin] = rank
                    gtinIndex[gtin] = fields
                }
            }
            for sku in skus {
                if (skuRanks[sku] ?? -1) < rank {
                    skuRanks[sku] = rank
                    skuIndex[sku] = fields
                }
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

    /// Bambuddy's `effect_type` for SpoolmanDB's finish fields. Structure first, as Bambuddy
    /// draws it (a coaxial two-colour filament is a split however it's finished), then glow,
    /// pattern, translucency, and matte last. Glossy is the default finish: no effect.
    /// How likely a size is to be the box in hand when one code covers several: 1.75 mm beats
    /// 2.85 mm, then 1 kg beats the bigger spools.
    nonisolated static func sizeRank(diameter: Double?, weight: Double?) -> Int {
        (diameter.map { abs($0 - 1.75) < 0.01 } == true ? 2 : 0) + (weight.map { abs($0 - 1000) < 1 } == true ? 1 : 0)
    }

    nonisolated static func effect(finish: String?, pattern: String?, multiColorDirection: String?, colorCount: Int, glow: Bool, translucent: Bool) -> String? {
        switch multiColorDirection?.lowercased() {
        case "coaxial": return colorCount == 2 ? "dual-color" : colorCount == 3 ? "tri-color" : "multicolor"
        case "longitudinal": return "gradient"
        default: break
        }
        if glow { return "glow" }
        switch pattern?.lowercased() {
        case "sparkle": return "sparkle"
        case "marble": return "marble"
        case "wood": return "wood"
        default: break
        }
        if translucent { return "translucent" }
        switch finish?.lowercased() {
        case "matte": return "matte"
        case "silk": return "silk"
        default: return nil
        }
    }

    private static func hex6(_ raw: String) -> String? {
        let h = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard h.count >= 6, h.prefix(6).allSatisfy(\.isHexDigit) else { return nil }
        return String(h.prefix(6)).uppercased()
    }

    private static func hexToRGBA(_ hex: String?) -> String? {
        guard var h = hex else { return nil }
        h = h.hasPrefix("#") ? String(h.dropFirst()) : h
        guard h.count == 6, h.allSatisfy(\.isHexDigit) else { return nil }
        return h.uppercased() + "FF"
    }

    /// Mirrors `FilamentCode.canon` without hopping to `@MainActor` during off-main indexing.
    private static func canonicalGTIN(_ barcode: String) -> String {
        let digits = barcode.filter(\.isNumber)
        let stripped = digits.drop { $0 == "0" }
        return stripped.isEmpty ? "0" : String(stripped)
    }
}
