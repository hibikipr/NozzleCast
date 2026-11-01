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
    /// The printer's Developer LAN mode: true = on, false = off, nil = not reported. With it off,
    /// Bambu firmware rejects print-control commands (pause/resume/stop, homing) over LAN, while
    /// reads, the camera and the chamber light keep working.
    var developerMode: Bool?
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
    /// The AMS slot currently feeding, as Bambu's global tray id: `ams_id * 4 + slot`, an AMS HT
    /// unit's own id (128+), 254+ for an external spool, 255 for none.
    var trayNow: Int?
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
    var maintenanceItems: [BambuddyMaintenanceItemDTO]?
}

/// One maintenance task on a printer, with Bambuddy's own due/warning verdict.
struct BambuddyMaintenanceItemDTO: Codable {
    var id: Int
    var maintenanceTypeName: String
    /// A lucide icon name from Bambuddy's web UI, e.g. "Droplet", "Flame".
    var maintenanceTypeIcon: String?
    var maintenanceTypeWikiUrl: String?
    var enabled: Bool
    /// The interval, in print hours — or in days when `intervalType` is "days".
    var intervalHours: Double
    /// "hours" (print hours) or "days" (calendar days).
    var intervalType: String
    var hoursSinceMaintenance: Double
    var hoursUntilDue: Double
    var daysSinceMaintenance: Double?
    var daysUntilDue: Double?
    var isDue: Bool
    var isWarning: Bool
    var lastPerformedAt: String?
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
    /// Free-text location. Spoolman mode's only location when Bambuddy couldn't match it to one
    /// of its own locations (`locationId` nil); unused in built-in mode.
    var storageLocation: String?
    /// True when `colorName` isn't a real color name but Bambuddy's stand-in: Spoolman has no
    /// color-name field, so its proxy copies the filament's name (e.g. "Matte Desert Tan") into
    /// it. Always false/absent in built-in mode.
    var colorNameIsSynthesized: Bool?
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
    /// This spool's own low-stock alert level in percent; nil uses the server-wide
    /// `low_stock_threshold` setting. Spoolman spools never carry one.
    var lowStockThresholdPct: Int?
    /// The manufacturer's article/material number (Bambuddy 1.2.5.7).
    var materialNumber: String?
    var lastUsed: String?
    /// Where this spool can be bought (Bambuddy 1.2.5.7). Built-in inventory only — Spoolman
    /// mode keeps suppliers behind a separate per-spool endpoint.
    var suppliers: [BambuddySpoolSupplierDTO]?
    /// The NFC tag linked to this spool: a chip UID, and for a Bambu spool the tray UUID both of
    /// its tags share. Both nil for a spool with no tag.
    var tagUid: String?
    var trayUuid: String?
}

struct BambuddySpoolSupplierDTO: Codable {
    var supplierId: Int
    var supplierName: String
    var supplierArticleNumber: String?
    var quotedPricePerKg: Double?
    var isPurchaseSource: Bool?
}

/// One print's draw on a spool (`GET /inventory/spools/{id}/usage`).
struct BambuddySpoolUsageDTO: Codable {
    var id: Int
    var printerId: Int?
    var printName: String?
    var weightUsed: Double
    var percentUsed: Int?
    var status: String
    var cost: Double?
    var createdAt: String
}

/// An entry on Bambuddy's filament shopping list — a SKU to buy, not a spool.
struct BambuddyShoppingListItemDTO: Codable {
    var id: Int
    var material: String
    var subtype: String?
    var brand: String?
    var colorName: String?
    var quantitySpools: Int
    var note: String?
    /// pending, purchased, received.
    var status: String
    var purchasedAt: String?
    var addedAt: String?
}

struct ShoppingListItemCreateBody: Codable {
    var material: String
    var subtype: String?
    var brand: String?
    var colorName: String?
    var quantitySpools: Int
}

private struct ShoppingListStatusBody: Codable {
    var status: String
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

/// Which inventory Bambuddy is serving: its own database, or Spoolman.
///
/// In Spoolman mode Bambuddy keeps the same spool format but serves it from a translating proxy
/// at `/api/v1/spoolman/inventory`, so spool reads and edits differ only by base path; slot
/// assignments are the one shape that differs (see `assignments()`, `assignSpool`, `unassign`).
/// Locations and the color catalog stay on the built-in routes in both modes — Bambuddy mirrors
/// Spoolman's locations into its own table and adds `location_id` to proxied spools.
enum InventoryBackend: Equatable, Sendable {
    case builtIn
    case spoolman

    var basePath: String {
        switch self {
        case .builtIn: "/api/v1/inventory"
        case .spoolman: "/api/v1/spoolman/inventory"
        }
    }
}

/// `GET /api/v1/spoolman/status`. `enabled` is Bambuddy's "use Spoolman for inventory" switch;
/// `connected` is only evaluated while it's on.
struct BambuddySpoolmanStatusDTO: Codable {
    var enabled: Bool
    var connected: Bool
}

/// One row of `GET /api/v1/spoolman/inventory/slot-assignments/all` — Spoolman mode's
/// equivalent of `BambuddyAssignmentDTO`, keyed by the Spoolman spool id.
private struct SpoolmanSlotAssignmentDTO: Codable {
    var printerId: Int
    var printerName: String?
    var amsId: Int
    var trayId: Int
    var spoolmanSpoolId: Int
}

private struct SpoolmanSlotAssignBody: Codable {
    var spoolmanSpoolId: Int
    var printerId: Int
    var amsId: Int
    var trayId: Int
}

enum InventoryBackendError: LocalizedError {
    case unassignNeedsSpool

    var errorDescription: String? {
        String(localized: "That slot has no known spool to unassign.")
    }
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
    // Only sent when set (synthesized Codable skips nil), so a plain add is the same request as
    // before. Spoolman mode takes subtype, core weight and the slicer profile, and ignores the rest.
    var subtype: String?
    var extraColors: String?
    var effectType: String?
    var coreWeight: Int?
    var coreWeightCatalogId: Int?
    var slicerFilament: String?
    var slicerFilamentName: String?
    var nozzleTempMin: Int?
    var nozzleTempMax: Int?
}

/// The spool fields a new spool can carry beyond the review form's material, colour, brand and
/// weight — what a decoded Bambu tag says (see `SpoolBuddyTagDataDTO.createExtras`).
struct SpoolCreateExtras: Equatable {
    /// RRGGBBAA to save instead of the form's colour with an opaque alpha: a tag's own colour,
    /// whose alpha says a translucent filament is translucent.
    var rgba: String?
    var subtype: String?
    var extraColors: String?
    var effectType: String?
    var coreWeight: Int?
    var coreWeightCatalogId: Int?
    var slicerFilament: String?
    var slicerFilamentName: String?
    var nozzleTempMin: Int?
    var nozzleTempMax: Int?
}

// MARK: - Notification log

/// One alert Bambuddy sent to one of its notification providers (ntfy, Pushover, Discord, email,
/// …) — `GET /notifications/logs`. The same alert sent to two providers is two rows.
struct BambuddyNotificationLogDTO: Codable {
    var id: Int
    var eventType: String
    var title: String
    var message: String
    var success: Bool
    var printerId: Int?
    var printerName: String?
    var createdAt: String
}

// MARK: - Print queue & history

/// One job in Bambuddy's print queue (`GET /queue/`). Only what the Queue screen shows; the
/// response carries much more (plate, calibration flags, AMS mapping, batch, …).
struct BambuddyQueueItemDTO: Codable {
    var id: Int
    var printerId: Int?
    var printerName: String?
    /// A job queued for "any printer of this model" rather than one printer.
    var targetModel: String?
    var archiveId: Int?
    var libraryFileId: Int?
    var archiveName: String?
    var libraryFileName: String?
    var position: Int
    /// pending, printing, completed, failed, skipped, cancelled.
    var status: String
    /// Staged: waits for someone to press Start rather than dispatching when the printer frees up.
    var manualStart: Bool
    var scheduledTime: String?
    var waitingReason: String?
    var printTimeSeconds: Int?
    var filamentUsedGrams: Double?
    var filamentType: String?
    var filamentColor: String?
    var confirmOutcome: Bool?
    var errorMessage: String?
}

/// One row of Bambuddy's print log (`GET /print-log/`) — a single run of a print. Reprints of the
/// same file are separate rows sharing an `archiveId`.
struct BambuddyPrintLogEntryDTO: Codable {
    var id: Int
    var archiveId: Int?
    var printName: String?
    var printerName: String?
    var printerId: Int?
    /// completed, failed, cancelled, … as Bambuddy recorded it.
    var status: String
    var startedAt: String?
    var completedAt: String?
    var durationSeconds: Int?
    var filamentType: String?
    var filamentColor: String?
    var filamentUsedGrams: Double?
    var cost: Double?
    var failureReason: String?
    /// The user's "how did it come out" answer (Bambuddy #1898): good, reject, or nil.
    var userVerdict: String?
    var thumbnailPath: String?
    var createdAt: String
}

struct BambuddyPrintLogPageDTO: Codable {
    var items: [BambuddyPrintLogEntryDTO]
    var total: Int
}

private struct QueueReorderBody: Codable {
    struct Item: Codable { var id: Int; var position: Int }
    var items: [Item]
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
    /// Where spool and slot-assignment requests go — see `InventoryBackend`. Resolved from the
    /// server on every refresh (`inventoryBackend()`), so switching Bambuddy between its own
    /// inventory and Spoolman is followed without any setting in the app.
    var inventory: InventoryBackend = .builtIn

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

    /// Records a maintenance task as done now, restarting its interval.
    func performMaintenance(itemID: Int) async throws {
        _ = try await send(request("/api/v1/maintenance/items/\(itemID)/perform", method: "POST", body: Data("{}".utf8)))
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

    /// Every spool, archived ones included. Bambuddy's list excludes archived spools unless
    /// `include_archived=true` is passed, and `AppStore.refresh()` splits the result into
    /// `spools` and `archivedSpools` itself. Without the flag the Archived filter was always
    /// empty, however many spools were actually archived.
    func spools() async throws -> [BambuddySpoolDTO] {
        try await get("\(inventory.basePath)/spools", query: [URLQueryItem(name: "include_archived", value: "true")])
    }

    /// Which inventory the server is serving. Asks `/spoolman/status`, which needs the
    /// `filaments:read` permission; an API key without it (401/403) falls back to checking
    /// whether the Spoolman inventory proxy answers, which needs only `inventory:read` and
    /// replies 400 "not enabled" in built-in mode. Anything inconclusive means built-in — the
    /// default every Bambuddy has.
    func inventoryBackend() async -> InventoryBackend {
        do {
            let status: BambuddySpoolmanStatusDTO = try await get("/api/v1/spoolman/status")
            return status.enabled ? .spoolman : .builtIn
        } catch BambuddyAPIError.http(let code, _) where code == 401 || code == 403 {
            let answered = (try? await send(request("/api/v1/spoolman/inventory/spools"))) != nil
            return answered ? .spoolman : .builtIn
        } catch {
            return .builtIn
        }
    }

    func assignments() async throws -> [BambuddyAssignmentDTO] {
        switch inventory {
        case .builtIn:
            return try await get("/api/v1/inventory/assignments")
        case .spoolman:
            let rows: [SpoolmanSlotAssignmentDTO] = try await get("/api/v1/spoolman/inventory/slot-assignments/all")
            // Mapped onto the built-in shape: only the slot and the spool id are ever read.
            return rows.map {
                BambuddyAssignmentDTO(id: 0, spoolId: $0.spoolmanSpoolId, printerId: $0.printerId, printerName: $0.printerName, amsId: $0.amsId, trayId: $0.trayId, spool: nil)
            }
        }
    }

    /// The server-wide low-stock alert level (percent remaining), from Bambuddy's settings. The
    /// settings response is large; only this field is decoded.
    func lowStockThreshold() async throws -> Double? {
        struct Response: Decodable { var lowStockThreshold: Double? }
        let response: Response = try await get("/api/v1/settings/")
        return response.lowStockThreshold
    }

    /// Newest first. Built-in inventory only; Bambuddy has no Spoolman equivalent.
    func spoolUsage(spoolID: Int, limit: Int) async throws -> [BambuddySpoolUsageDTO] {
        try await get("/api/v1/inventory/spools/\(spoolID)/usage", query: [URLQueryItem(name: "limit", value: String(limit))])
    }

    /// Newest first. The same list in both inventory modes.
    func shoppingList() async throws -> [BambuddyShoppingListItemDTO] {
        try await get("/api/v1/inventory/shopping-list")
    }

    /// Bambuddy doesn't merge duplicates — callers check the list first.
    func addToShoppingList(_ item: ShoppingListItemCreateBody) async throws {
        _ = try await send(request("/api/v1/inventory/shopping-list", method: "POST", body: try encoder.encode(item)))
    }

    /// `pending`, `purchased` or `received`.
    func setShoppingListStatus(itemID: Int, status: String) async throws {
        let body = try encoder.encode(ShoppingListStatusBody(status: status))
        _ = try await send(request("/api/v1/inventory/shopping-list/\(itemID)/status", method: "PATCH", body: body))
    }

    func removeFromShoppingList(itemID: Int) async throws {
        _ = try await send(request("/api/v1/inventory/shopping-list/\(itemID)", method: "DELETE"))
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

    /// The live MJPEG stream (`multipart/x-mixed-replace`) for a printer's camera. Authenticated
    /// by the stream token in the URL alone, so it can be loaded directly in a web view — unlike
    /// Bambuddy's `/camera/<id>` page, which only gets a token when the browser is logged in.
    func cameraStreamURL(printerID: Int, token: String, fps: Int = 15) -> URL? {
        var components = URLComponents(url: baseURL.appendingPathComponent("/api/v1/printers/\(printerID)/camera/stream"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "fps", value: String(fps)), URLQueryItem(name: "token", value: token)]
        return components?.url
    }

    /// Tells Bambuddy this viewer is done with the printer's stream, as its own camera page does
    /// on close. Reference-counted server-side: it never cuts off another viewer, and Bambuddy
    /// also shuts an unwatched stream down on its own after a few seconds.
    func stopCameraStream(printerID: Int) async throws {
        _ = try await send(request("/api/v1/printers/\(printerID)/camera/stop", method: "POST"))
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

    // MARK: Notification log

    /// Newest first, from the last `days` days. Needs the API key's `notifications:read`.
    func notificationLog(limit: Int, days: Int = 7) async throws -> [BambuddyNotificationLogDTO] {
        try await get("/api/v1/notifications/logs", query: [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "days", value: String(days)),
        ])
    }

    // MARK: Print queue & history

    /// The whole queue, every status — the caller picks out what's still to come.
    func queue() async throws -> [BambuddyQueueItemDTO] {
        try await get("/api/v1/queue/")
    }

    /// Newest first.
    func printLog(limit: Int, offset: Int) async throws -> BambuddyPrintLogPageDTO {
        try await get("/api/v1/print-log/", query: [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ])
    }

    /// The plate thumbnail saved with a print-log row. 404 when the print was archived without one.
    func printLogThumbnailData(entryID: Int) async throws -> Data {
        try await send(request("/api/v1/print-log/\(entryID)/thumbnail"))
    }

    func archiveThumbnailData(archiveID: Int) async throws -> Data {
        try await send(request("/api/v1/archives/\(archiveID)/thumbnail"))
    }

    func libraryFileThumbnailData(fileID: Int) async throws -> Data {
        try await send(request("/api/v1/library/files/\(fileID)/thumbnail"))
    }

    /// Records "how did it come out" on a print's archive: `"good"`, `"reject"`, or nil to clear
    /// it. Bambuddy copies the verdict onto the archive's latest print-log row (its #1444 mirror),
    /// which is the row the History screen shows, and retires the one-tap link in any
    /// notification it sent for the print. `dialog` is the source Bambuddy's own prompt claims —
    /// a person answered it, as opposed to a script (`api`).
    func setVerdict(archiveID: Int, verdict: String?) async throws {
        let payload: [String: Any] = verdict.map { ["user_verdict": $0, "user_verdict_source": "dialog"] } ?? ["user_verdict": NSNull()]
        let body = try JSONSerialization.data(withJSONObject: payload)
        _ = try await send(request("/api/v1/archives/\(archiveID)", method: "PATCH", body: body))
    }

    /// Releases a staged (`manualStart`) job: Bambuddy clears the flag and its scheduler sends the
    /// job to the printer once the printer is free.
    func startQueueItem(itemID: Int) async throws {
        _ = try await send(request("/api/v1/queue/\(itemID)/start", method: "POST"))
    }

    /// Takes a job out of the queue. Bambuddy refuses for a job that's printing.
    func removeQueueItem(itemID: Int) async throws {
        _ = try await send(request("/api/v1/queue/\(itemID)", method: "DELETE"))
    }

    /// Sets the given pending jobs' positions; Bambuddy ignores ids that aren't pending.
    func reorderQueue(_ positions: [(id: Int, position: Int)]) async throws {
        let body = try encoder.encode(QueueReorderBody(items: positions.map { .init(id: $0.id, position: $0.position) }))
        _ = try await send(request("/api/v1/queue/reorder", method: "POST", body: body))
    }

    // MARK: Inventory mutations

    func assignSpool(spoolID: Int, printerID: Int, amsID: Int, trayID: Int) async throws {
        switch inventory {
        case .builtIn:
            let body = try encoder.encode(AssignmentCreateBody(spoolId: spoolID, printerId: printerID, amsId: amsID, trayId: trayID))
            _ = try await send(request("/api/v1/inventory/assignments", method: "POST", body: body))
        case .spoolman:
            let body = try encoder.encode(SpoolmanSlotAssignBody(spoolmanSpoolId: spoolID, printerId: printerID, amsId: amsID, trayId: trayID))
            _ = try await send(request("/api/v1/spoolman/inventory/slot-assignments", method: "POST", body: body))
        }
    }

    /// Built-in mode removes an assignment by its slot; Spoolman mode only by the assigned
    /// spool's id, so `spoolID` is required there.
    func unassign(printerID: Int, amsID: Int, trayID: Int, spoolID: Int?) async throws {
        switch inventory {
        case .builtIn:
            _ = try await send(request("/api/v1/inventory/assignments/\(printerID)/\(amsID)/\(trayID)", method: "DELETE"))
        case .spoolman:
            guard let spoolID else { throw InventoryBackendError.unassignNeedsSpool }
            _ = try await send(request("/api/v1/spoolman/inventory/slot-assignments/\(spoolID)", method: "DELETE"))
        }
    }

    @discardableResult
    func createSpool(material: String, colorName: String, rgba: String, brand: String, labelWeight: Int, extras: SpoolCreateExtras = SpoolCreateExtras()) async throws -> BambuddySpoolDTO {
        let body = try encoder.encode(SpoolCreateBody(
            material: material, colorName: colorName, rgba: rgba, brand: brand, labelWeight: labelWeight,
            subtype: extras.subtype, extraColors: extras.extraColors, effectType: extras.effectType,
            coreWeight: extras.coreWeight, coreWeightCatalogId: extras.coreWeightCatalogId,
            slicerFilament: extras.slicerFilament, slicerFilamentName: extras.slicerFilamentName,
            nozzleTempMin: extras.nozzleTempMin, nozzleTempMax: extras.nozzleTempMax
        ))
        let data = try await send(request("\(inventory.basePath)/spools", method: "POST", body: body))
        do {
            return try decoder.decode(BambuddySpoolDTO.self, from: data)
        } catch {
            throw BambuddyAPIError.decoding(error)
        }
    }

    /// Soft delete: Bambuddy sets the spool's `archived_at`, and it drops out of the inventory
    /// list (`AppStore.refresh()` filters archived spools). Reversible with `restoreSpool`.
    func archiveSpool(spoolID: Int) async throws {
        _ = try await send(request("\(inventory.basePath)/spools/\(spoolID)/archive", method: "POST"))
    }

    /// Clears `archived_at` on a spool archived with `archiveSpool`.
    func restoreSpool(spoolID: Int) async throws {
        _ = try await send(request("\(inventory.basePath)/spools/\(spoolID)/restore", method: "POST"))
    }

    /// Permanently deletes the spool record. Not reversible — callers confirm first.
    func deleteSpool(spoolID: Int) async throws {
        _ = try await send(request("\(inventory.basePath)/spools/\(spoolID)", method: "DELETE"))
    }

    @discardableResult
    func updateSpool(spoolID: Int, _ update: BambuddySpoolUpdateBody) async throws -> BambuddySpoolDTO {
        let body = try encoder.encode(update)
        let data = try await send(request("\(inventory.basePath)/spools/\(spoolID)", method: "PATCH", body: body))
        do {
            return try decoder.decode(BambuddySpoolDTO.self, from: data)
        } catch {
            throw BambuddyAPIError.decoding(error)
        }
    }
}

// MARK: - SpoolBuddy

/// A SpoolBuddy (Raspberry Pi with an NFC reader and a scale) registered with Bambuddy.
struct BambuddySpoolBuddyDeviceDTO: Codable, Equatable {
    var deviceId: String
    var hostname: String
    var online: Bool
    /// Whether the device has a scale, and whether its last heartbeat said it works. Either is
    /// false when the scale is turned off or broken; the scale then sends no readings.
    var hasScale: Bool?
    var scaleOk: Bool?
}

private struct SpoolTagLinkBody: Codable {
    var tagUid: String
    var trayUuid: String?
}

extension BambuddyAPIClient {
    private struct WebSocketTokenResponse: Decodable { var token: String }

    /// Mints the short-lived token `/api/v1/ws` takes as `?token=`. The API key needs Bambuddy's
    /// `websocket:connect` permission. Nil from a server that predates the endpoint, whose socket
    /// takes no token.
    func webSocketToken() async throws -> String? {
        let data: Data
        do {
            data = try await send(request("/api/v1/auth/ws-token", method: "POST"))
        } catch BambuddyAPIError.http(404, _) {
            return nil
        }
        do {
            return try decoder.decode(WebSocketTokenResponse.self, from: data).token
        } catch {
            throw BambuddyAPIError.decoding(error)
        }
    }

    func spoolBuddyDevices() async throws -> [BambuddySpoolBuddyDeviceDTO] {
        try await get("/api/v1/spoolbuddy/devices")
    }

    /// Stores an NFC tag on a spool, so the next scan of that tag finds it. The two inventories
    /// name the route differently; a Bambu spool is matched by `trayUUID` (the same on both of
    /// its tags) ahead of the chip UID.
    func linkTag(spoolID: Int, tagUID: String, trayUUID: String?) async throws {
        let body = try encoder.encode(SpoolTagLinkBody(tagUid: tagUID, trayUuid: trayUUID))
        let path = switch inventory {
        case .builtIn: "\(inventory.basePath)/spools/\(spoolID)/link-tag"
        case .spoolman: "\(inventory.basePath)/spools/\(spoolID)/tag"
        }
        _ = try await send(request(path, method: "PATCH", body: body))
    }
}

/// The spool Bambuddy found for a scanned tag, as `spoolbuddy_tag_matched` carries it. Every field
/// but the id is optional: Spoolman-backed spools can leave any of them empty.
struct SpoolBuddyMatchedSpoolDTO: Codable, Equatable {
    var id: Int
    var material: String?
    var subtype: String?
    var colorName: String?
    var colorNameIsSynthesized: Bool?
    var rgba: String?
    var extraColors: String?
    var effectType: String?
    var brand: String?
    var labelWeight: Int?
    var coreWeight: Int?
    var weightUsed: Double?
}

/// What a scanned Bambu Lab tag says about its roll, decoded by Bambuddy: the `tag_data` of a
/// `spoolbuddy_unknown_tag` event (Bambuddy's #2685). It holds the spool values Bambuddy's AMS
/// auto-creation would set for the same roll — material, colour (named from Bambuddy's colour
/// catalog), slicer profile, temperatures, and the empty spool's weight. Nil from a Bambuddy older
/// than that, for a tag that isn't Bambu's, or from a SpoolBuddy daemon that doesn't send the tag's
/// data blocks.
struct SpoolBuddyTagDataDTO: Codable, Equatable {
    var material: String
    var subtype: String?
    var colorName: String?
    /// RRGGBBAA.
    var rgba: String?
    var extraColors: String?
    var effectType: String?
    var brand: String?
    var labelWeight: Int?
    var slicerFilament: String?
    var slicerFilamentName: String?
    var nozzleTempMin: Int?
    var nozzleTempMax: Int?
    var coreWeight: Int?
    var coreWeightCatalogId: Int?
    /// Bambu's variant code, e.g. "A00-B08". Shown only; Bambuddy has no spool field for it.
    var variantId: String?
    var diameter: Double?
    var dryingTemp: Int?
    var dryingTime: Int?

    /// "#RRGGBB" from `rgba`, or nil when it isn't a hex colour.
    var colorHex: String? {
        guard let rgba, rgba.count >= 6, rgba.prefix(6).allSatisfy(\.isHexDigit) else { return nil }
        return "#" + rgba.prefix(6).uppercased()
    }

    /// What the review form starts with for this roll.
    var scannedResult: ScannedResult {
        ScannedResult(
            material: FilamentMaterial.from(bambuddyMaterial: material),
            colorName: colorName ?? "",
            colorHex: colorHex ?? "#808080",
            brand: brand ?? "Bambu Lab",
            netWeightGrams: labelWeight ?? 1000,
            barcode: nil,
            alsoMatches: nil
        )
    }

    /// The material to save: the tag's own ("PETG", "ASA") while the form still shows what it
    /// started with — the form only offers four materials, so it can't hold every tag's — and the
    /// form's otherwise.
    func material(for form: ScannedResult) -> String {
        FilamentMaterial.from(bambuddyMaterial: material) == form.material ? material : form.material.rawValue
    }

    /// The tag's other spool fields, for the spool created from `form`. The core weight always
    /// applies — it's the spool, not the filament. The profile (subtype, slicer preset,
    /// temperatures) only while the form keeps the tag's material, and the tag's exact colour
    /// (with its alpha — translucent filaments' is below FF) and multicolour/effect details only
    /// while it keeps the tag's colour: after an edit they'd describe another filament.
    func createExtras(for form: ScannedResult) -> SpoolCreateExtras {
        var extras = SpoolCreateExtras(coreWeight: coreWeight, coreWeightCatalogId: coreWeightCatalogId)
        if FilamentMaterial.from(bambuddyMaterial: material) == form.material {
            extras.subtype = subtype
            extras.slicerFilament = slicerFilament
            extras.slicerFilamentName = slicerFilamentName
            extras.nozzleTempMin = nozzleTempMin
            extras.nozzleTempMax = nozzleTempMax
        }
        if let colorHex, colorHex.caseInsensitiveCompare(form.colorHex) == .orderedSame {
            extras.rgba = rgba?.uppercased()
            extras.extraColors = extraColors
            extras.effectType = effectType
        }
        return extras
    }
}

/// The SpoolBuddy messages Bambuddy broadcasts on `/api/v1/ws` (see its
/// `backend/app/api/routes/spoolbuddy.py`). Every other message on the socket is ignored.
enum SpoolBuddyEvent: Equatable {
    case tagMatched(deviceID: String, tagUID: String, trayUUID: String?, spool: SpoolBuddyMatchedSpoolDTO)
    /// A tag no spool carries. `trayUUID` is only set for a genuine Bambu tag, and `tagData` only
    /// when Bambuddy could decode one (see `SpoolBuddyTagDataDTO`).
    case unknownTag(deviceID: String, tagUID: String, trayUUID: String?, tagType: String?, tagData: SpoolBuddyTagDataDTO? = nil)
    case tagRemoved(deviceID: String, tagUID: String)
    /// The scale's gross reading: filament plus the empty spool.
    case weight(deviceID: String, grams: Double, stable: Bool)
    /// The tag was read but the lookup failed — `spoolmanUnavailable` when Bambuddy couldn't reach
    /// Spoolman, which says nothing about whether the tag is known.
    case lookupError(deviceID: String, spoolmanUnavailable: Bool)
    case online(deviceID: String, hostname: String?)
    case offline(deviceID: String)

    var deviceID: String {
        switch self {
        case .tagMatched(let id, _, _, _), .unknownTag(let id, _, _, _, _), .tagRemoved(let id, _),
             .weight(let id, _, _), .lookupError(let id, _), .online(let id, _), .offline(let id):
            id
        }
    }

    private struct Envelope: Decodable {
        var type: String
        var deviceId: String?
        var tagUid: String?
        var trayUuid: String?
        var tagType: String?
        var spool: SpoolBuddyMatchedSpoolDTO?
        var weightGrams: Double?
        var stable: Bool?
        var hostname: String?
        var context: String?
    }

    /// Decoded on its own, so a `tag_data` this build doesn't understand costs only the prefill,
    /// never the unknown-tag event itself.
    private struct TagDataEnvelope: Decodable {
        var tagData: SpoolBuddyTagDataDTO?
    }

    /// Nil for anything that isn't a well-formed SpoolBuddy event.
    static func decode(_ data: Data) -> SpoolBuddyEvent? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let e = try? decoder.decode(Envelope.self, from: data), let device = e.deviceId else { return nil }
        switch e.type {
        case "spoolbuddy_tag_matched":
            guard let tag = e.tagUid, let spool = e.spool else { return nil }
            return .tagMatched(deviceID: device, tagUID: tag, trayUUID: e.trayUuid, spool: spool)
        case "spoolbuddy_unknown_tag":
            guard let tag = e.tagUid else { return nil }
            let tagData = (try? decoder.decode(TagDataEnvelope.self, from: data))?.tagData
            return .unknownTag(deviceID: device, tagUID: tag, trayUUID: e.trayUuid, tagType: e.tagType, tagData: tagData)
        case "spoolbuddy_tag_removed":
            guard let tag = e.tagUid else { return nil }
            return .tagRemoved(deviceID: device, tagUID: tag)
        case "spoolbuddy_weight":
            guard let grams = e.weightGrams else { return nil }
            return .weight(deviceID: device, grams: grams, stable: e.stable ?? false)
        case "spoolbuddy_lookup_error":
            return .lookupError(deviceID: device, spoolmanUnavailable: false)
        case "spoolman_unavailable":
            // Also sent for Spoolman outages that have nothing to do with a scan.
            guard e.context == "nfc_tag_scanned" else { return nil }
            return .lookupError(deviceID: device, spoolmanUnavailable: true)
        case "spoolbuddy_online":
            return .online(deviceID: device, hostname: e.hostname)
        case "spoolbuddy_offline":
            return .offline(deviceID: device)
        default:
            return nil
        }
    }
}

// MARK: - WebSocket

/// One open socket. A seam for tests; the app uses `URLSessionBambuddyWebSocket`.
protocol BambuddyWebSocket: AnyObject {
    /// The next text message. Throws once the socket is closed.
    func receive() async throws -> String
    func send(_ text: String) async throws
    func cancel()
}

final class URLSessionBambuddyWebSocket: BambuddyWebSocket {
    private let task: URLSessionWebSocketTask

    init(url: URL, session: URLSession = .shared) {
        task = session.webSocketTask(with: url)
        task.resume()
    }

    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let text): text
        case .data(let data): String(decoding: data, as: UTF8.self)
        @unknown default: ""
        }
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

/// Bambuddy's live event socket, kept open with reconnects until `stop()`.
///
/// Every connection attempt mints a new token: Bambuddy refuses an expired one by dropping the
/// handshake, which looks no different from a network failure, so a cached token could fail
/// forever. Failed attempts back off exponentially (see `backoff(attempt:)`), and the count resets
/// once a connection answers. Run it only while something on screen needs it — iOS drops sockets
/// of a backgrounded app anyway.
@Observable
final class BambuddyEventStream {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        /// Waiting to retry after `attempt` failures in a row.
        case retrying(attempt: Int, reason: String?)
    }

    private(set) var state: State = .idle
    /// Called for each SpoolBuddy event, on the main actor.
    @ObservationIgnored var onEvent: ((SpoolBuddyEvent) -> Void)?

    @ObservationIgnored private let baseURL: URL
    @ObservationIgnored private let fetchToken: () async throws -> String?
    @ObservationIgnored private let makeSocket: (URL) -> BambuddyWebSocket
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private let pingInterval: Duration
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var socket: BambuddyWebSocket?

    init(
        baseURL: URL,
        fetchToken: @escaping () async throws -> String?,
        makeSocket: @escaping (URL) -> BambuddyWebSocket = { URLSessionBambuddyWebSocket(url: $0) },
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        pingInterval: Duration = .seconds(25)
    ) {
        self.baseURL = baseURL
        self.fetchToken = fetchToken
        self.makeSocket = makeSocket
        self.sleep = sleep
        self.pingInterval = pingInterval
    }

    convenience init(client: BambuddyAPIClient) {
        self.init(baseURL: client.baseURL, fetchToken: { try await client.webSocketToken() })
    }

    func start() {
        guard runTask == nil else { return }
        runTask = Task { await run() }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        socket?.cancel()
        socket = nil
        state = .idle
    }

    /// 1, 2, 4, 8, 16, then 30 seconds between attempts.
    static func backoff(attempt: Int) -> Duration {
        .seconds(min(30, 1 << min(max(attempt - 1, 0), 5)))
    }

    /// `/api/v1/ws` under `baseURL` (which may carry a path prefix behind a reverse proxy), on
    /// `ws`/`wss` to match `http`/`https`.
    static func webSocketURL(baseURL: URL, token: String?) -> URL? {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("/api/v1/ws"), resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: return nil
        }
        if let token { components.queryItems = [URLQueryItem(name: "token", value: token)] }
        return components.url
    }

    /// Connects and reconnects until cancelled, or until the sleeper throws.
    func run() async {
        var failures = 0
        while !Task.isCancelled {
            if failures == 0 { state = .connecting }
            var reason: String?
            do {
                guard let url = Self.webSocketURL(baseURL: baseURL, token: try await fetchToken()) else {
                    throw BambuddyAPIError.notConfigured
                }
                try Task.checkCancellation()
                let socket = makeSocket(url)
                self.socket = socket
                let pingInterval = pingInterval
                // An immediate ping, so the pong confirms the connection even when no printer
                // status follows; then one now and then, so idle proxies don't drop the socket.
                let pinger = Task {
                    while !Task.isCancelled {
                        try? await socket.send(#"{"type":"ping"}"#)
                        try? await Task.sleep(for: pingInterval)
                    }
                }
                defer {
                    pinger.cancel()
                    socket.cancel()
                }
                while !Task.isCancelled {
                    let text = try await socket.receive()
                    if state != .connected {
                        failures = 0
                        state = .connected
                    }
                    if let event = SpoolBuddyEvent.decode(Data(text.utf8)) {
                        onEvent?(event)
                    }
                }
            } catch {
                reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            socket = nil
            if Task.isCancelled { break }
            failures += 1
            state = .retrying(attempt: failures, reason: reason)
            do {
                try await sleep(Self.backoff(attempt: failures))
            } catch {
                break
            }
        }
    }
}
