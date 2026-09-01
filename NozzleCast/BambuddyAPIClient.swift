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
            String(localized: "Bambuddy server isn't configured.")
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
    /// the angled 3D perspective view by default. Shares the camera stream-token auth flow.
    func coverImageData(printerID: Int, token: String) async throws -> Data {
        try await send(request("/api/v1/printers/\(printerID)/cover", query: [URLQueryItem(name: "token", value: token)]))
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
}
