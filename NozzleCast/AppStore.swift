import SwiftUI
import Observation

enum ConnectionStatus: Equatable {
    case notConfigured
    case connecting
    case connected(username: String)
    case failed(String)
}

@Observable
final class AppStore {
    var printers: [Printer] = []
    var spools: [Spool] = []
    var config: BambuddyConfig
    var connectionStatus: ConnectionStatus = .notConfigured
    var grantedPermissions: Set<String> = []
    var isRefreshing = false

    private var locationNames: [Int: String] = [:]

    init(config: BambuddyConfig) {
        self.config = config
        if config.isConfigured {
            connectionStatus = .connecting
            Task { await testConnectionAndRefresh() }
        } else {
            loadMockData()
        }
    }

    var isLive: Bool { config.isConfigured && connectionStatusIsUsable }

    private var connectionStatusIsUsable: Bool {
        if case .failed = connectionStatus { return false }
        if case .notConfigured = connectionStatus { return false }
        return true
    }

    private var client: BambuddyAPIClient? {
        guard let url = config.serverURL, !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return BambuddyAPIClient(baseURL: url, apiKey: config.apiKey)
    }

    func loadMockData() {
        printers = MockData.makePrinters()
        spools = MockData.makeSpools()
    }

    func printer(_ id: String) -> Printer? { printers.first { $0.id == id } }
    func printerName(_ id: String) -> String? { printer(id)?.name }
    func spool(_ id: String?) -> Spool? {
        guard let id else { return nil }
        return spools.first { $0.id == id }
    }

    // MARK: - Connection

    @discardableResult
    func testConnectionAndRefresh() async -> Bool {
        guard let client else {
            connectionStatus = .notConfigured
            loadMockData()
            return false
        }
        connectionStatus = .connecting
        do {
            let me = try await client.me()
            grantedPermissions = Set(me.permissions)
            connectionStatus = .connected(username: me.username)
            await refresh()
            return true
        } catch {
            connectionStatus = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            loadMockData()
            return false
        }
    }

    func refresh() async {
        guard let client else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let printerDTOs = client.printers()
            async let spoolDTOs = client.spools()
            async let assignmentDTOs = client.assignments()
            async let locationDTOs = client.locations()

            let (printerList, spoolList, assignmentList, locationList) = try await (printerDTOs, spoolDTOs, assignmentDTOs, locationDTOs)

            locationNames = Dictionary(uniqueKeysWithValues: locationList.map { ($0.id, $0.name) })

            let statuses: [Int: BambuddyStatusDTO] = try await withThrowingTaskGroup(of: (Int, BambuddyStatusDTO).self) { group in
                for p in printerList {
                    group.addTask { (p.id, try await client.status(printerID: p.id)) }
                }
                var result: [Int: BambuddyStatusDTO] = [:]
                for try await (id, status) in group { result[id] = status }
                return result
            }

            var assignmentsByPrinterSlot: [String: BambuddyAssignmentDTO] = [:]
            var assignmentsBySpoolID: [Int: BambuddyAssignmentDTO] = [:]
            for a in assignmentList {
                assignmentsByPrinterSlot["\(a.printerId)-\(a.amsId)-\(a.trayId)"] = a
                assignmentsBySpoolID[a.spoolId] = a
            }

            printers = printerList.map { dto in
                Self.mapPrinter(dto, status: statuses[dto.id], assignmentsByPrinterSlot: assignmentsByPrinterSlot)
            }

            spools = spoolList
                .filter { $0.archivedAt == nil }
                .map { Self.mapSpool($0, assignment: assignmentsBySpoolID[$0.id], locationNames: locationNames) }
        } catch {
            connectionStatus = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: - Mapping

    private static func assetName(forModel model: String) -> String? {
        let m = model.uppercased()
        if m.contains("X1C") || m.contains("X1 CARBON") { return "PrinterX1C" }
        if m.contains("X1E") { return "PrinterX1E" }
        if m.contains("P1S") { return "PrinterP1S" }
        if m.contains("P1P") { return "PrinterP1P" }
        if m.contains("P2S") { return "PrinterP2S" }
        if m.contains("H2C") { return "PrinterH2C" }
        if m.contains("H2S") { return "PrinterH2S" }
        if m.contains("H2D") { return "PrinterH2D" }
        if m.contains("X2D") { return "PrinterX2D" }
        if m.contains("A2L") { return "PrinterA2L" }
        if m == "A1" { return "PrinterA1" }
        return nil
    }

    private static func mapState(_ dto: BambuddyStatusDTO?) -> PrinterState {
        guard let dto else { return .offline }
        if !dto.connected { return .offline }
        switch dto.state.uppercased() {
        case "RUNNING", "PRINTING", "PREPARE", "SLICING": return .printing
        case "PAUSE", "PAUSED": return .paused
        case "FAILED", "ERROR": return .error
        default: return .idle
        }
    }

    private static func mapPrinter(_ dto: BambuddyPrinterDTO, status: BambuddyStatusDTO?, assignmentsByPrinterSlot: [String: BambuddyAssignmentDTO]) -> Printer {
        let id = "bb-\(dto.id)"
        let state = mapState(status)
        let temps = status?.temperatures

        func reading(current: Double?, target: Double?) -> TemperatureReading {
            TemperatureReading(current: Int((current ?? 0).rounded()), target: (target ?? 0) > 0 ? Int((target ?? 0).rounded()) : nil)
        }

        let chamber: TemperatureReading? = temps?.chamber.map { TemperatureReading(current: Int($0.rounded()), target: nil) }

        let amsUnits: [AMSUnit] = (status?.ams ?? []).map { unit in
            AMSUnit(
                index: unit.id,
                trays: unit.tray.map { tray in
                    let assignment = assignmentsByPrinterSlot["\(dto.id)-\(unit.id)-\(tray.id)"]
                    return AMSTray(amsIndex: unit.id, trayIndex: tray.id, spoolID: assignment.map { "bb-\($0.spoolId)" })
                },
                isHT: unit.isAmsHt ?? false
            )
        }

        let progress = (status?.progress).map { $0 / 100 }
        let remaining = status?.remainingTime
        let job = state == .printing || state == .paused ? status?.subtaskName : nil

        return Printer(
            id: id,
            name: dto.name,
            model: dto.model,
            imageAssetName: assetName(forModel: dto.model),
            state: state,
            jobFileName: (job?.isEmpty == false) ? job : nil,
            progress: (state == .printing || state == .paused) ? progress : nil,
            etaMinutesRemaining: (state == .printing || state == .paused) ? remaining : nil,
            nozzle: reading(current: temps?.nozzle, target: temps?.nozzleTarget),
            bed: reading(current: temps?.bed, target: temps?.bedTarget),
            chamber: chamber,
            lightOn: false,
            amsUnits: amsUnits
        )
    }

    private static func mapSpool(_ dto: BambuddySpoolDTO, assignment: BambuddyAssignmentDTO?, locationNames: [Int: String]) -> Spool {
        let percentRemaining: Int
        if let used = dto.weightUsed, let label = dto.labelWeight, label > 0 {
            percentRemaining = max(0, min(100, Int((100.0 * (1 - used / Double(label))).rounded())))
        } else {
            percentRemaining = 100
        }

        let location: SpoolLocation
        if let assignment {
            location = .ams(printerID: "bb-\(assignment.printerId)", amsIndex: assignment.amsId, trayIndex: assignment.trayId)
        } else {
            location = .storage(name: dto.locationId.flatMap { locationNames[$0] })
        }

        return Spool(
            id: "bb-\(dto.id)",
            material: .from(bambuddyMaterial: dto.material),
            colorName: dto.colorName ?? dto.material,
            colorHex: "#" + (dto.rgba?.prefix(6).uppercased() ?? "808080"),
            brand: dto.brand ?? "Unknown",
            remainingPercent: percentRemaining,
            netWeightGrams: dto.labelWeight ?? 1000,
            location: location
        )
    }

    private func bambuddyID(_ localID: String) -> Int? {
        guard localID.hasPrefix("bb-") else { return nil }
        return Int(localID.dropFirst(3))
    }

    // MARK: - Camera

    /// Fetches one live snapshot for a printer's chamber camera. Mints a fresh stream token
    /// per call since the API gives no expiry, and snapshots are only polled every few seconds.
    func cameraSnapshot(printerID: String) async -> UIImage? {
        guard let client, let bbID = bambuddyID(printerID) else { return nil }
        do {
            let token = try await client.cameraStreamToken()
            let data = try await client.cameraSnapshotData(printerID: bbID, token: token)
            return UIImage(data: data)
        } catch {
            return nil
        }
    }

    // MARK: - Printer controls

    func togglePause(_ printerID: String) {
        guard let idx = printers.firstIndex(where: { $0.id == printerID }) else { return }
        let wasPrinting = printers[idx].state == .printing
        printers[idx].state = wasPrinting ? .paused : .printing

        guard isLive, let client, let bbID = bambuddyID(printerID) else { return }
        Task {
            do {
                if wasPrinting { try await client.pause(printerID: bbID) } else { try await client.resume(printerID: bbID) }
                await refresh()
            } catch {
                connectionStatus = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func stop(_ printerID: String) {
        guard let idx = printers.firstIndex(where: { $0.id == printerID }) else { return }
        printers[idx].state = .idle
        printers[idx].jobFileName = nil
        printers[idx].progress = nil
        printers[idx].etaMinutesRemaining = nil

        guard isLive, let client, let bbID = bambuddyID(printerID) else { return }
        Task {
            do {
                try await client.stop(printerID: bbID)
                await refresh()
            } catch {
                connectionStatus = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func toggleLight(_ printerID: String) {
        guard let idx = printers.firstIndex(where: { $0.id == printerID }) else { return }
        printers[idx].lightOn.toggle()
        let newValue = printers[idx].lightOn

        guard isLive, let client, let bbID = bambuddyID(printerID) else { return }
        Task {
            do {
                try await client.setChamberLight(printerID: bbID, on: newValue)
            } catch {
                connectionStatus = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    // MARK: - AMS assignment

    func assign(spoolID: String, toPrinter printerID: String, amsIndex: Int, trayIndex: Int) {
        for i in printers.indices {
            for t in printers[i].amsUnits.indices {
                for s in printers[i].amsUnits[t].trays.indices where printers[i].amsUnits[t].trays[s].spoolID == spoolID {
                    printers[i].amsUnits[t].trays[s].spoolID = nil
                }
            }
        }
        guard let idx = printers.firstIndex(where: { $0.id == printerID }),
              let unitIdx = printers[idx].amsUnits.firstIndex(where: { $0.index == amsIndex }),
              let trayIdx = printers[idx].amsUnits[unitIdx].trays.firstIndex(where: { $0.trayIndex == trayIndex }) else { return }
        printers[idx].amsUnits[unitIdx].trays[trayIdx].spoolID = spoolID

        if let sIdx = spools.firstIndex(where: { $0.id == spoolID }) {
            spools[sIdx].location = .ams(printerID: printerID, amsIndex: amsIndex, trayIndex: trayIndex)
        }

        guard isLive, let client, let bbPrinterID = bambuddyID(printerID), let bbSpoolID = bambuddyID(spoolID) else { return }
        Task {
            do {
                try await client.assignSpool(spoolID: bbSpoolID, printerID: bbPrinterID, amsID: amsIndex, trayID: trayIndex)
                await refresh()
            } catch {
                connectionStatus = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func unassign(printerID: String, amsIndex: Int, trayIndex: Int) {
        guard let idx = printers.firstIndex(where: { $0.id == printerID }),
              let unitIdx = printers[idx].amsUnits.firstIndex(where: { $0.index == amsIndex }),
              let trayIdx = printers[idx].amsUnits[unitIdx].trays.firstIndex(where: { $0.trayIndex == trayIndex }) else { return }
        let spoolID = printers[idx].amsUnits[unitIdx].trays[trayIdx].spoolID
        printers[idx].amsUnits[unitIdx].trays[trayIdx].spoolID = nil
        if let spoolID, let sIdx = spools.firstIndex(where: { $0.id == spoolID }) {
            spools[sIdx].location = .storage(name: nil)
        }

        guard isLive, let client, let bbPrinterID = bambuddyID(printerID) else { return }
        Task {
            do {
                try await client.unassign(printerID: bbPrinterID, amsID: amsIndex, trayID: trayIndex)
                await refresh()
            } catch {
                connectionStatus = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    // MARK: - Inventory

    @discardableResult
    func addSpool(material: FilamentMaterial, colorName: String, colorHex: String, brand: String, netWeightGrams: Int) -> Spool {
        if isLive, let client {
            let rgba = colorHex.replacingOccurrences(of: "#", with: "").uppercased() + "FF"
            Task {
                do {
                    _ = try await client.createSpool(material: material.rawValue, colorName: colorName, rgba: rgba, brand: brand, labelWeight: netWeightGrams)
                    await refresh()
                } catch {
                    connectionStatus = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            }
        }

        let spool = Spool(
            id: isLive ? "pending-\(UUID().uuidString)" : "mock-spool-\(UUID().uuidString)",
            material: material,
            colorName: colorName,
            colorHex: colorHex,
            brand: brand,
            remainingPercent: 100,
            netWeightGrams: netWeightGrams,
            location: .storage(name: nil)
        )
        spools.insert(spool, at: 0)
        return spool
    }
}
