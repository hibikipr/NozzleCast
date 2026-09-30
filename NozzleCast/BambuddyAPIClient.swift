import Foundation

// MARK: - DTOs (snake_case JSON decoded via .convertFromSnakeCase)

struct BambuddyAuthMeDTO: Codable {
    var username: String
    var permissions: [String]
}

struct BambuddyPrinterDTO: Codable {
    var id: Int
    var name: String
    var model: String
}

struct BambuddyTemperaturesDTO: Codable {
    var bed: Double?
    var bedTarget: Double?
    var nozzle: Double?
    var nozzleTarget: Double?
    /// Right nozzle's reading on a dual-nozzle printer (Bambuddy's `nozzle_2`/`nozzle_2_target`).
    var nozzle2: Double?
    var nozzle2Target: Double?
    var chamber: Double?
    var chamberTarget: Double?
}

struct BambuddyTrayDTO: Codable {
    var id: Int
    var trayColor: String?
    var trayType: String?
    var traySubBrands: String?
    var remain: Int?
    var exists: Bool?
}

struct BambuddyAMSUnitDTO: Codable {
    var id: Int
    var tray: [BambuddyTrayDTO]
    var isAmsHt: Bool?
    var humidity: Int?
    var temp: Double?
    /// 0 when idle; any other value means the unit is actively running a drying cycle.
    var dryStatus: Int?
    var dryTargetTemp: Int?
    var dryFilament: String?
}

struct BambuddyHMSErrorDTO: Codable {
    var severity: Int
    var fullCode: String
    var description: String?
}

struct BambuddyNozzleDTO: Codable {
    var nozzleType: String
    var nozzleDiameter: String
}

struct BambuddyNozzleRackSlotDTO: Codable {
    var id: Int
    var nozzleDiameter: String
    var maxTemp: Int
    var serialNumber: String
    var filamentColor: String
}

struct BambuddyStatusDTO: Codable {
    var id: Int
    var name: String
    var connected: Bool
    var state: String
    var subtaskName: String?
    var progress: Double?
    var remainingTime: Int?
    var layerNum: Int?
    var totalLayers: Int?
    var temperatures: BambuddyTemperaturesDTO?
    var ams: [BambuddyAMSUnitDTO]?
    /// Spool bays fed directly rather than through an AMS (fixed ids 254/255 = left/right nozzle).
    var vtTray: [BambuddyTrayDTO]?
    var wifiSignal: Int?
    var doorOpen: Bool?
    var firmwareVersion: String?
    var hmsErrors: [BambuddyHMSErrorDTO]?
    var nozzles: [BambuddyNozzleDTO]?
    var nozzleRack: [BambuddyNozzleRackSlotDTO]?
    /// AMS/HT unit id (as a string key) -> "A" (left nozzle) or "B" (right nozzle).
    var amsSwitchInlet: [String: String]?
    var coolingFanSpeed: Int?
    var bigFan1Speed: Int?
    var bigFan2Speed: Int?
    var chamberLight: Bool?
    var awaitingPlateClear: Bool?
    /// Human-readable name for the printer's current internal stage (Bambuddy's `stg_cur`
    /// resolved server-side), e.g. "Purifying the chamber air", "Heating chamber", "Cooling
    /// heatbed" — detail beyond the coarse RUNNING/PAUSE/FINISH `state`. In particular this is
    /// what's actually happening during the awkward window after a print reaches 100% but before
    /// `gcode_state` moves off RUNNING, where the printer is auto-running its post-print chamber
    /// purification. Nil when there's no derived stage worth naming (idle, or a plain "Printing"
    /// that would only repeat what `state` already says).
    var stgCurName: String?
}

struct BambuddyMaintenanceSummaryDTO: Codable {
    var totalPrintHours: Double
    var dueCount: Int
    var warningCount: Int
}

struct BambuddySmartPlugSummaryDTO: Codable {
    var id: Int
    var name: String
}

struct BambuddySmartPlugEnergyDTO: Codable {
    var power: Double?
}

struct BambuddySmartPlugStatusDTO: Codable {
    var state: String?
    var reachable: Bool
    var energy: BambuddySmartPlugEnergyDTO?
}

/// Decodes any JSON value while discarding its content — used for `per_printer`, whose entry
/// shape isn't documented and isn't needed here; only which printer ids are present as keys
/// (currently-monitored printers) matters.
struct BambuddyIgnoredValue: Codable {
    init(from decoder: Decoder) throws {}
    func encode(to encoder: Encoder) throws {}
}

/// Bambuddy's integration with Obico, a self-hosted AI print-failure ("spaghetti") detection
/// service — optional and account-wide, not a native printer feature.
struct BambuddyObicoStatusDTO: Codable {
    var enabled: Bool
    /// Keyed by Bambuddy printer id (as a string) — presence of a key means that printer is
    /// currently being monitored.
    var perPrinter: [String: BambuddyIgnoredValue]
    var lastError: String?
}

struct BambuddySpoolDTO: Codable {
    var id: Int
    var material: String
    var subtype: String?
    var colorName: String?
    var rgba: String?
    var brand: String?
    var labelWeight: Int?
    var weightUsed: Double?
    var locationId: Int?
    var archivedAt: String?
    var slicerFilament: String?
    var nozzleTempMin: Int?
    var nozzleTempMax: Int?
    var costPerKg: Double?
    var category: String?
    var note: String?
    /// Comma-separated hex stops, e.g. "EC984C,6CD4BC,A66EB9" — a dual/multi-color spool.
    var extraColors: String?
    /// Swatch finish, e.g. "silk", "sparkle", "matte", "translucent". Nil for a plain filament.
    var effectType: String?
}

/// Partial update for a spool — only non-nil fields are sent, matching Bambuddy's PATCH
/// semantics (an omitted field leaves the existing value alone). Scoped to the fields
/// NozzleCast's edit screen actually exposes; Bambuddy's full SpoolUpdate schema has several
/// more (effect_type, core_weight, weight_locked, low_stock_threshold_pct, location_id,
/// tag/RFID fields) not editable here yet.
struct BambuddySpoolUpdateBody: Encodable {
    var material: String?
    var subtype: String?
    var colorName: String?
    var rgba: String?
    var extraColors: String?
    var brand: String?
    var labelWeight: Int?
    var slicerFilament: String?
    var nozzleTempMin: Int?
    var nozzleTempMax: Int?
    var costPerKg: Double?
    var category: String?
    var note: String?
}

struct BambuddyAssignmentDTO: Codable {
    var id: Int
    var spoolId: Int
    var printerId: Int
    var printerName: String?
    var amsId: Int
    var trayId: Int
    var spool: BambuddySpoolDTO?
}

struct BambuddyLocationDTO: Codable {
    var id: Int
    var name: String
}

struct BambuddyNotificationProviderConfigDTO: Codable {
    var server: String?
    var topic: String?
    var authToken: String?
}

/// One configured notification destination (ntfy, Pushover, Discord, …) from Bambuddy's
/// `/api/v1/notifications/` endpoint. Only the fields NozzleCast needs are modeled — the
/// endpoint also returns ~35 `on_*` event-type flags and quiet-hours/digest settings we don't
/// use here (Bambuddy's server does its own event filtering before publishing to ntfy).
struct BambuddyNotificationProviderDTO: Codable {
    var id: Int
    var name: String
    var providerType: String
    var enabled: Bool
    var config: BambuddyNotificationProviderConfigDTO
}

private struct AssignmentCreateBody: Codable {
    var spoolId: Int
    var printerId: Int
    var amsId: Int
    var trayId: Int
}

private struct SpoolCreateBody: Codable {
    var material: String
    var colorName: String?
    var rgba: String?
    var brand: String?
    var labelWeight: Int
}

// MARK: - Errors

enum BambuddyAPIError: LocalizedError {
    case notConfigured
    case invalidResponse
    case http(Int, String)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            String(localized: "Printer server isn't configured.")
        case .invalidResponse:
            String(localized: "Received an unexpected response from the server.")
        case .http(let code, let message):
            message.isEmpty
                ? String(localized: "Server returned \(code)")
                : String(localized: "Server returned \(code): \(message)")
        case .decoding(let error):
            String(localized: "Couldn't parse the server response (\(error.localizedDescription)).")
        }
    }
}

// MARK: - Client

struct BambuddyAPIClient {
    var baseURL: URL
    var apiKey: String

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        // URLSession's default is 60s. Most calls run inside a refresh made of several dependent
        // rounds of requests, sometimes from a background wake with ~30s to live in total, where
        // one stalled request at the default would outlast the whole budget on its own.
        req.timeoutInterval = 15
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw BambuddyAPIError.invalidResponse }
        if http.statusCode == 421 {
            // HTTP/2 connection coalescing: iOS reused a stale channel for a different hostname
            // and the server (openresty/nginx) rejected it. RFC 9113 says the client SHOULD retry
            // with a fresh connection — URLSession.shared doesn't do this automatically, so we
            // open an ephemeral session that forces a new TCP+TLS handshake.
            NSLog("NCDEBUG 421 Misdirected Request, retrying with fresh session")
            let fresh = URLSession(configuration: .ephemeral)
            defer { fresh.finishTasksAndInvalidate() }
            let (data2, response2) = try await fresh.data(for: req)
            guard let http2 = response2 as? HTTPURLResponse else { throw BambuddyAPIError.invalidResponse }
            guard (200..<300).contains(http2.statusCode) else {
                throw BambuddyAPIError.http(http2.statusCode, String(data: data2, encoding: .utf8) ?? "")
            }
            return data2
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw BambuddyAPIError.http(http.statusCode, message)
        }
        return data
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await send(request(path, query: query))
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw BambuddyAPIError.decoding(error)
        }
    }

    // MARK: Reads

    func me() async throws -> BambuddyAuthMeDTO {
        try await get("/api/v1/auth/me")
    }

    func printers() async throws -> [BambuddyPrinterDTO] {
        try await get("/api/v1/printers/")
    }

    func status(printerID: Int) async throws -> BambuddyStatusDTO {
        try await get("/api/v1/printers/\(printerID)/status")
    }

    func maintenanceSummary(printerID: Int) async throws -> BambuddyMaintenanceSummaryDTO {
        try await get("/api/v1/maintenance/printers/\(printerID)")
    }

    func obicoStatus() async throws -> BambuddyObicoStatusDTO {
        try await get("/api/v1/obico/printer-status")
    }

    /// Nil when the printer has no smart plug configured (the endpoint returns a bare `null`).
    func smartPlug(printerID: Int) async throws -> BambuddySmartPlugSummaryDTO? {
        try await get("/api/v1/smart-plugs/by-printer/\(printerID)")
    }

    func smartPlugStatus(plugID: Int) async throws -> BambuddySmartPlugStatusDTO {
        try await get("/api/v1/smart-plugs/\(plugID)/status")
    }

    func spools() async throws -> [BambuddySpoolDTO] {
        try await get("/api/v1/inventory/spools")
    }

    func assignments() async throws -> [BambuddyAssignmentDTO] {
        try await get("/api/v1/inventory/assignments")
    }

    func locations() async throws -> [BambuddyLocationDTO] {
        try await get("/api/v1/inventory/locations")
    }

    /// Compact `{hex(lowercase, 6 chars, no '#'): color name}` map from Bambuddy's own curated
    /// color catalog — the same one its own web UI loads to resolve a spool's display name when
    /// `color_name` is missing or is a raw internal code (e.g. "A06-D0") rather than something
    /// presentable, falling back to the color's hex instead. Fetched once and cached by the
    /// caller (`AppStore`): it's small, curated data that essentially never changes mid-session,
    /// so re-fetching it on every 30s refresh tick would be pure waste.
    ///
    /// The response body is `{"colors": {hex: name, ...}}`, NOT a bare map at the top level —
    /// confirmed against the route's actual `return` statement and against Bambuddy's own React
    /// client (`api.getColorNameMap()` types this exact endpoint as `{ colors: Record<string,
    /// string> }` and unwraps `.colors`). A previous version of this method decoded straight into
    /// `[String: String]`, going only by the route's docstring ("Compact `{hex: name}` map")
    /// without checking the literal `return` line beneath it — a real, envelope-shaped response
    /// decoded as a bare dictionary throws a type-mismatch `DecodingError`, which the caller's
    /// `try?` swallows with zero signal, leaving `colorCatalog` permanently empty. That silently
    /// broke every spool whose `color_name` needed this catalog to resolve at all: not a partial
    /// miss, a 100% failure, confirmed live (spool 38 "Rose Gold" kept showing "PLA" after this
    /// exact fallback shipped).
    func colorCatalogMap() async throws -> [String: String] {
        struct Response: Decodable { var colors: [String: String] }
        let response: Response = try await get("/api/v1/inventory/colors/map")
        return response.colors
    }

    func notificationProviders() async throws -> [BambuddyNotificationProviderDTO] {
        try await get("/api/v1/notifications/")
    }

    // MARK: Controls

    func pause(printerID: Int) async throws {
        _ = try await send(request("/api/v1/printers/\(printerID)/print/pause", method: "POST"))
    }

    func resume(printerID: Int) async throws {
        _ = try await send(request("/api/v1/printers/\(printerID)/print/resume", method: "POST"))
    }

    func stop(printerID: Int) async throws {
        _ = try await send(request("/api/v1/printers/\(printerID)/print/stop", method: "POST"))
    }

    func setChamberLight(printerID: Int, on: Bool) async throws {
        _ = try await send(request(
            "/api/v1/printers/\(printerID)/chamber-light",
            method: "POST",
            query: [URLQueryItem(name: "on", value: on ? "true" : "false")]
        ))
    }

    func homeAxes(printerID: Int) async throws {
        _ = try await send(request("/api/v1/printers/\(printerID)/home-axes", method: "POST"))
    }

    func clearPlate(printerID: Int) async throws {
        _ = try await send(request("/api/v1/printers/\(printerID)/clear-plate", method: "POST"))
    }

    func rereadRFID(printerID: Int, amsID: Int, trayID: Int) async throws {
        _ = try await send(request("/api/v1/printers/\(printerID)/ams/\(amsID)/slot/\(trayID)/refresh", method: "POST"))
    }

    func setSmartPlug(plugID: Int, on: Bool) async throws {
        let body = try encoder.encode(["action": on ? "on" : "off"])
        _ = try await send(request("/api/v1/smart-plugs/\(plugID)/control", method: "POST", body: body))
    }

    // MARK: Camera

    private struct StreamTokenResponse: Decodable { var token: String }

    /// Snapshots require a short-lived token (separate from the API key) minted by this endpoint.
    func cameraStreamToken() async throws -> String {
        let data = try await send(request("/api/v1/printers/camera/stream-token", method: "POST"))
        do {
            return try decoder.decode(StreamTokenResponse.self, from: data).token
        } catch {
            throw BambuddyAPIError.decoding(error)
        }
    }

    func cameraSnapshotData(printerID: Int, token: String) async throws -> Data {
        try await send(request("/api/v1/printers/\(printerID)/camera/snapshot", query: [URLQueryItem(name: "token", value: token)]))
    }

    /// The rendered plate preview for the current (or most recently finished) print job —
    /// the angled 3D perspective view by default.
    ///
    /// Authenticated by the API key's Bearer header alone, like every other printer read — no
    /// camera stream token. Bambuddy moved `/cover` from `camera:view` (via the stream token) to
    /// `printers:read` (its #3025: seeing what's on the plate isn't a camera permission), and the
    /// relay confirmed live that a plain Bearer request succeeds with no token (nozzlecast-relay
    /// #23). Minting a token first was a wasted request per cover fetch.
    func coverImageData(printerID: Int) async throws -> Data {
        try await send(request("/api/v1/printers/\(printerID)/cover"))
    }

    // MARK: Inventory mutations

    func assignSpool(spoolID: Int, printerID: Int, amsID: Int, trayID: Int) async throws {
        let body = try encoder.encode(AssignmentCreateBody(spoolId: spoolID, printerId: printerID, amsId: amsID, trayId: trayID))
        _ = try await send(request("/api/v1/inventory/assignments", method: "POST", body: body))
    }

    func unassign(printerID: Int, amsID: Int, trayID: Int) async throws {
        _ = try await send(request("/api/v1/inventory/assignments/\(printerID)/\(amsID)/\(trayID)", method: "DELETE"))
    }

    @discardableResult
    func createSpool(material: String, colorName: String, rgba: String, brand: String, labelWeight: Int) async throws -> BambuddySpoolDTO {
        let body = try encoder.encode(SpoolCreateBody(material: material, colorName: colorName, rgba: rgba, brand: brand, labelWeight: labelWeight))
        let data = try await send(request("/api/v1/inventory/spools", method: "POST", body: body))
        do {
            return try decoder.decode(BambuddySpoolDTO.self, from: data)
        } catch {
            throw BambuddyAPIError.decoding(error)
        }
    }

    @discardableResult
    /// Soft delete: Bambuddy sets the spool's `archived_at`, and it drops out of the inventory
    /// list (`AppStore.refresh()` filters archived spools). Reversible with `restoreSpool`.
    func archiveSpool(spoolID: Int) async throws {
        _ = try await send(request("/api/v1/inventory/spools/\(spoolID)/archive", method: "POST"))
    }

    /// Clears `archived_at` on a spool archived with `archiveSpool`.
    func restoreSpool(spoolID: Int) async throws {
        _ = try await send(request("/api/v1/inventory/spools/\(spoolID)/restore", method: "POST"))
    }

    /// Permanently deletes the spool record. Not reversible — callers confirm first.
    func deleteSpool(spoolID: Int) async throws {
        _ = try await send(request("/api/v1/inventory/spools/\(spoolID)", method: "DELETE"))
    }

    func updateSpool(spoolID: Int, _ update: BambuddySpoolUpdateBody) async throws -> BambuddySpoolDTO {
        let body = try encoder.encode(update)
        let data = try await send(request("/api/v1/inventory/spools/\(spoolID)", method: "PATCH", body: body))
        do {
            return try decoder.decode(BambuddySpoolDTO.self, from: data)
        } catch {
            throw BambuddyAPIError.decoding(error)
        }
    }
}
