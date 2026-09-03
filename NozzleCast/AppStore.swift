import SwiftUI
import Observation
import NozzleCastShared

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

    /// True while there's no printer data to show yet and we're still working on it - distinct
    /// from "connected with genuinely zero printers registered," which isn't a loading state.
    /// `connectionStatus` flips to `.connected` as soon as auth succeeds, a beat before
    /// `refresh()` actually populates `printers`/`spools`; without also checking `isRefreshing`
    /// here, that gap renders as "0 printing · 0 printers" instead of a loading state.
    var isLoadingPrinters: Bool { isLoading(dataIsEmpty: printers.isEmpty) }
    var isLoadingSpools: Bool { isLoading(dataIsEmpty: spools.isEmpty) }

    private func isLoading(dataIsEmpty: Bool) -> Bool {
        guard dataIsEmpty else { return false }
        switch connectionStatus {
        case .connecting: return true
        case .connected: return isRefreshing
        case .failed, .notConfigured: return false
        }
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

    /// Looks up the ntfy notification provider Bambuddy is already configured to publish
    /// printer alerts to, and subscribes NozzleCast's push manager to that same topic. Silently
    /// no-ops if Bambuddy has no enabled ntfy provider — this only pairs with a server the user
    /// has already set up to relay through Firebase, it doesn't create one.
    @discardableResult
    func discoverAndSubscribeNtfy() async -> Bool {
        guard let client else { return false }
        guard let providers = try? await client.notificationProviders(),
              let ntfy = providers.first(where: { $0.providerType == "ntfy" && $0.enabled }),
              let server = ntfy.config.server, let topic = ntfy.config.topic
        else { return false }
        PushNotificationManager.shared.subscribe(server: server, topic: topic, authToken: ntfy.config.authToken)
        return true
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
            // Account-wide, optional, and not part of a printer's own status - fetched
            // separately and allowed to fail without affecting anything else in the refresh.
            async let obicoTask: BambuddyObicoStatusDTO? = try? client.obicoStatus()

            let (printerList, spoolList, assignmentList, locationList) = try await (printerDTOs, spoolDTOs, assignmentDTOs, locationDTOs)
            let obico = await obicoTask

            locationNames = Dictionary(uniqueKeysWithValues: locationList.map { ($0.id, $0.name) })

            let extras: [Int: PrinterExtras] = try await withThrowingTaskGroup(of: (Int, PrinterExtras).self) { group in
                for p in printerList {
                    group.addTask {
                        async let statusTask: BambuddyStatusDTO? = try? client.status(printerID: p.id)
                        async let maintenanceTask: BambuddyMaintenanceSummaryDTO? = try? client.maintenanceSummary(printerID: p.id)

                        var smartPlug: (BambuddySmartPlugSummaryDTO, BambuddySmartPlugStatusDTO)?
                        if let plugInfo: BambuddySmartPlugSummaryDTO = try? await client.smartPlug(printerID: p.id) {
                            if let plugStatus: BambuddySmartPlugStatusDTO = try? await client.smartPlugStatus(plugID: plugInfo.id) {
                                smartPlug = (plugInfo, plugStatus)
                            }
                        }

                        let extras = PrinterExtras(status: await statusTask, maintenance: await maintenanceTask, smartPlug: smartPlug)
                        return (p.id, extras)
                    }
                }
                var result: [Int: PrinterExtras] = [:]
                for try await (id, extras) in group { result[id] = extras }
                return result
            }

            var assignmentsByPrinterSlot: [String: BambuddyAssignmentDTO] = [:]
            var assignmentsBySpoolID: [Int: BambuddyAssignmentDTO] = [:]
            for a in assignmentList {
                assignmentsByPrinterSlot["\(a.printerId)-\(a.amsId)-\(a.trayId)"] = a
                assignmentsBySpoolID[a.spoolId] = a
            }

            printers = printerList.map { dto in
                Self.mapPrinter(dto, extras: extras[dto.id] ?? PrinterExtras(status: nil, maintenance: nil, smartPlug: nil), obico: obico, assignmentsByPrinterSlot: assignmentsByPrinterSlot)
            }

            // The cover render is static for the whole print, so only fetch it once per job
            // rather than on every refresh — the Live Activity manager tells us who already has one.
            let printersNeedingCover = printers.filter { $0.state == .printing && !PrintLiveActivityManager.shared.hasCoverImage(printerName: $0.name) }
            var coverImages: [String: Data] = [:]
            if !printersNeedingCover.isEmpty {
                await withTaskGroup(of: (String, Data?).self) { group in
                    for printer in printersNeedingCover {
                        group.addTask {
                            // The API call itself still needs Bambuddy's real numeric id; only the
                            // dictionary key handed to the Live Activity manager uses the name-based one.
                            let image = await self.printerCoverImage(printerID: printer.id)
                            return (PrintActivityAttributes.normalizedID(printer.name), image.flatMap { PrintLiveActivityManager.downscaledCoverImage($0) })
                        }
                    }
                    for await (id, data) in group {
                        if let data { coverImages[id] = data }
                    }
                }
            }
            await PrintLiveActivityManager.shared.sync(printers: printers, coverImages: coverImages)

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

    /// Everything fetched alongside the core status call for one printer, each independently
    /// optional so a maintenance/smart-plug hiccup for one printer never blanks its status too.
    private struct PrinterExtras {
        var status: BambuddyStatusDTO?
        var maintenance: BambuddyMaintenanceSummaryDTO?
        var smartPlug: (info: BambuddySmartPlugSummaryDTO, status: BambuddySmartPlugStatusDTO)?
    }

    /// `hasQualifyingHMSError` mirrors Bambuddy's own `classifyPrinterStatus` (confirmed against
    /// its frontend source, `frontend/src/pages/PrintersPage.tsx`): a bare `FAILED` gcode_state
    /// with no real HMS error attached is the printer's terminal state after *any* unsuccessful
    /// end — including a plain user cancellation — and Bambuddy explicitly treats that the same
    /// as `FINISH`, not as an error. Only an actual qualifying HMS code escalates to `.error`.
    /// Without this, a printer sat idle after a stopped/failed print with no real fault showed
    /// "Error" indefinitely, contradicting Bambuddy's own dashboard showing it as fine.
    private static func mapState(_ dto: BambuddyStatusDTO?, hasQualifyingHMSError: Bool) -> PrinterState {
        guard let dto else { return .offline }
        if !dto.connected { return .offline }
        if hasQualifyingHMSError { return .error }
        switch dto.state.uppercased() {
        case "RUNNING", "PRINTING", "PREPARE", "SLICING": return .printing
        case "PAUSE", "PAUSED": return .paused
        default: return .idle
        }
    }

    private static func mapPrinter(_ dto: BambuddyPrinterDTO, extras: PrinterExtras, obico: BambuddyObicoStatusDTO?, assignmentsByPrinterSlot: [String: BambuddyAssignmentDTO]) -> Printer {
        let id = "bb-\(dto.id)"
        let status = extras.status
        let hmsErrors: [HMSError] = (status?.hmsErrors ?? []).map { hms in
            HMSError(fullCode: hms.fullCode, severity: hms.severity, description: hms.description)
        }
        // Severity <=3 (Bambuddy's own Fatal/Serious/Warning) qualifies as a real issue; severity
        // 4/Info (e.g. a "Developer Mode not enabled" advisory) does not — same threshold used
        // for the Live Activity's issue badge, so the two surfaces agree on what counts as an
        // actual problem worth surfacing versus routine chatter.
        let state = mapState(status, hasQualifyingHMSError: hmsErrors.contains { $0.severity <= 3 })
        let temps = status?.temperatures

        func reading(current: Double?, target: Double?) -> TemperatureReading {
            TemperatureReading(current: Int((current ?? 0).rounded()), target: (target ?? 0) > 0 ? Int((target ?? 0).rounded()) : nil)
        }

        let chamber: TemperatureReading? = temps?.chamber.map { TemperatureReading(current: Int($0.rounded()), target: nil) }
        // A printer only reports a right-nozzle reading once it actually has one, so its presence
        // is what tells us this is a dual-nozzle printer (rather than trusting `nozzles.count`,
        // which some firmware versions report inconsistently while idle).
        let rightNozzle: TemperatureReading? = temps?.nozzle2.map { reading(current: $0, target: temps?.nozzle2Target) }

        let amsSwitchInlet = status?.amsSwitchInlet ?? [:]
        func feedsRightNozzle(unitID: Int) -> Bool? {
            switch amsSwitchInlet[String(unitID)] {
            case "A": return false
            case "B": return true
            default: return nil
            }
        }

        let amsUnits: [AMSUnit] = (status?.ams ?? []).map { unit in
            AMSUnit(
                index: unit.id,
                trays: unit.tray.map { tray in
                    let assignment = assignmentsByPrinterSlot["\(dto.id)-\(unit.id)-\(tray.id)"]
                    return AMSTray(
                        amsIndex: unit.id,
                        trayIndex: tray.id,
                        spoolID: assignment.map { "bb-\($0.spoolId)" },
                        isLoaded: tray.exists ?? false,
                        rawColorHex: tray.trayColor.flatMap { $0.isEmpty ? nil : "#" + $0.prefix(6).uppercased() },
                        rawMaterialLabel: tray.trayType?.isEmpty == false ? tray.trayType : nil
                    )
                },
                isHT: unit.isAmsHt ?? false,
                humidity: unit.humidity,
                temperature: unit.temp,
                feedsRightNozzle: feedsRightNozzle(unitID: unit.id),
                isDrying: (unit.dryStatus ?? 0) != 0,
                dryTargetTemp: unit.dryTargetTemp,
                dryFilament: unit.dryFilament?.isEmpty == false ? unit.dryFilament : nil
            )
        }

        let externalTrays: [AMSTray] = (status?.vtTray ?? []).enumerated().map { index, tray in
            AMSTray(
                amsIndex: -1,
                trayIndex: index,
                spoolID: nil,
                isLoaded: tray.exists ?? false,
                rawColorHex: tray.trayColor.flatMap { $0.isEmpty ? nil : "#" + $0.prefix(6).uppercased() },
                rawMaterialLabel: tray.trayType?.isEmpty == false ? tray.trayType : nil
            )
        }

        let nozzles: [NozzleInfo] = (status?.nozzles ?? []).enumerated().map { index, n in
            NozzleInfo(index: index, type: n.nozzleType, diameter: n.nozzleDiameter)
        }

        let nozzleRack: [NozzleRackSlot] = (status?.nozzleRack ?? []).map { slot in
            NozzleRackSlot(
                id: slot.id,
                diameter: slot.nozzleDiameter,
                maxTemp: slot.maxTemp,
                isEmpty: slot.serialNumber.isEmpty || slot.serialNumber == "N/A",
                filamentColorHex: slot.filamentColor.isEmpty ? nil : "#" + slot.filamentColor.prefix(6).uppercased()
            )
        }

        var smartPlug: SmartPlugInfo?
        if let plug = extras.smartPlug {
            smartPlug = SmartPlugInfo(
                id: plug.info.id,
                name: plug.info.name,
                isOn: plug.status.state?.uppercased() == "ON",
                watts: plug.status.energy?.power
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
            currentLayer: (state == .printing || state == .paused) ? status?.layerNum : nil,
            totalLayers: (state == .printing || state == .paused) ? status?.totalLayers : nil,
            nozzle: reading(current: temps?.nozzle, target: temps?.nozzleTarget),
            rightNozzle: rightNozzle,
            bed: reading(current: temps?.bed, target: temps?.bedTarget),
            chamber: chamber,
            lightOn: status?.chamberLight ?? false,
            amsUnits: amsUnits,
            externalTrays: externalTrays,
            wifiSignalDBm: status?.wifiSignal,
            firmwareVersion: status?.firmwareVersion,
            hmsErrors: hmsErrors,
            doorOpen: status?.doorOpen ?? false,
            fanSpeeds: FanSpeeds(partCooling: status?.coolingFanSpeed, auxiliary: status?.bigFan1Speed, chamber: status?.bigFan2Speed),
            awaitingPlateClear: status?.awaitingPlateClear ?? false,
            nozzles: nozzles,
            nozzleRack: nozzleRack,
            totalPrintHours: extras.maintenance?.totalPrintHours,
            maintenanceOK: extras.maintenance.map { $0.dueCount == 0 && $0.warningCount == 0 },
            smartPlug: smartPlug,
            aiDetectionEnabled: obico?.enabled ?? false,
            aiMonitoringActive: obico?.perPrinter[String(dto.id)] != nil,
            aiLastError: obico?.lastError
        )
    }

    /// "EC984C,#6CD4BC, a66eb9" -> ["#EC984C", "#6CD4BC", "#A66EB9"] — tolerant of the leading
    /// "#" being present or not and stray whitespace, since that's user-typed input.
    private static func parseExtraColors(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(separator: ",").compactMap { part in
            let hex = part.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            guard !hex.isEmpty else { return nil }
            return "#" + hex.uppercased()
        }
    }

    private static func formatExtraColors(_ hexes: [String]) -> String? {
        let cleaned = hexes.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased() }.filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned.joined(separator: ",")
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
            material: dto.material,
            colorName: dto.colorName ?? dto.material,
            colorHex: "#" + (dto.rgba?.prefix(6).uppercased() ?? "808080"),
            extraColorHexes: parseExtraColors(dto.extraColors),
            brand: dto.brand ?? "Unknown",
            remainingPercent: percentRemaining,
            netWeightGrams: dto.labelWeight ?? 1000,
            location: location,
            subtype: dto.subtype,
            slicerFilamentID: dto.slicerFilament,
            nozzleTempMin: dto.nozzleTempMin,
            nozzleTempMax: dto.nozzleTempMax,
            costPerKg: dto.costPerKg,
            category: dto.category,
            note: dto.note
        )
    }

    private func bambuddyID(_ localID: String) -> Int? {
        guard localID.hasPrefix("bb-") else { return nil }
        return Int(localID.dropFirst(3))
    }

    // MARK: - Camera

    /// Last camera-snapshot failure per printer (keyed by local ID), so the UI can show *why*
    /// a live feed isn't loading instead of silently falling back to a placeholder icon.
    private(set) var cameraErrors: [String: String] = [:]

    /// Fetches one live snapshot for a printer's chamber camera. Mints a fresh stream token
    /// per call since the API gives no expiry, and snapshots are only polled every few seconds.
    func cameraSnapshot(printerID: String) async -> UIImage? {
        guard let client, let bbID = bambuddyID(printerID) else {
            cameraErrors[printerID] = String(localized: "Not connected to a Bambuddy server.")
            return nil
        }
        do {
            let token = try await client.cameraStreamToken()
            let data = try await client.cameraSnapshotData(printerID: bbID, token: token)
            guard let image = UIImage(data: data) else {
                cameraErrors[printerID] = String(localized: "Server sent \(data.count) bytes that aren't a decodable image.")
                return nil
            }
            cameraErrors[printerID] = nil
            return image
        } catch {
            cameraErrors[printerID] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// Fetches the rendered plate preview (angled 3D view) for a printer's current or most
    /// recently finished job — same stream-token auth as `cameraSnapshot`.
    func printerCoverImage(printerID: String) async -> UIImage? {
        guard let client, let bbID = bambuddyID(printerID) else { return nil }
        do {
            let token = try await client.cameraStreamToken()
            let data = try await client.coverImageData(printerID: bbID, token: token)
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

    func toggleSmartPlug(_ printerID: String) {
        guard let idx = printers.firstIndex(where: { $0.id == printerID }), let plug = printers[idx].smartPlug else { return }
        let newValue = !plug.isOn
        printers[idx].smartPlug?.isOn = newValue

        guard isLive, let client else { return }
        Task {
            do {
                try await client.setSmartPlug(plugID: plug.id, on: newValue)
            } catch {
                connectionStatus = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func homeAxes(_ printerID: String) {
        guard isLive, let client, let bbID = bambuddyID(printerID) else { return }
        Task {
            do {
                try await client.homeAxes(printerID: bbID)
            } catch {
                connectionStatus = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func clearPlate(_ printerID: String) {
        guard let idx = printers.firstIndex(where: { $0.id == printerID }) else { return }
        printers[idx].awaitingPlateClear = false

        guard isLive, let client, let bbID = bambuddyID(printerID) else { return }
        Task {
            do {
                try await client.clearPlate(printerID: bbID)
                await refresh()
            } catch {
                connectionStatus = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// Deep link into Bambuddy's own web UI for this printer's live camera page.
    func webCameraURL(printerID: String) -> URL? {
        guard let serverURL = config.serverURL, let bbID = bambuddyID(printerID) else { return nil }
        return serverURL.appendingPathComponent("camera/\(bbID)")
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

    func rereadRFID(printerID: String, amsIndex: Int, trayIndex: Int) {
        guard isLive, let client, let bbPrinterID = bambuddyID(printerID) else { return }
        Task {
            do {
                try await client.rereadRFID(printerID: bbPrinterID, amsID: amsIndex, trayID: trayIndex)
                await refresh()
            } catch {
                connectionStatus = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    // MARK: - Inventory

    @discardableResult
    func addSpool(material: String, colorName: String, colorHex: String, brand: String, netWeightGrams: Int) -> Spool {
        if isLive, let client {
            let rgba = colorHex.replacingOccurrences(of: "#", with: "").uppercased() + "FF"
            Task {
                do {
                    _ = try await client.createSpool(material: material, colorName: colorName, rgba: rgba, brand: brand, labelWeight: netWeightGrams)
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

    /// Edits a spool's own record (material/color/brand/weight/cost/notes/etc.) — separate from
    /// `assign`, which only links an existing spool to a printer slot. This is inventory
    /// bookkeeping only, same as assign: it does not push anything to physical AMS hardware.
    func updateSpool(
        _ spoolID: String,
        material: String,
        colorName: String,
        colorHex: String,
        extraColorHexes: [String],
        brand: String,
        subtype: String?,
        netWeightGrams: Int,
        nozzleTempMin: Int?,
        nozzleTempMax: Int?,
        costPerKg: Double?,
        category: String?,
        note: String?
    ) {
        guard let idx = spools.firstIndex(where: { $0.id == spoolID }) else { return }
        spools[idx].material = material
        spools[idx].colorName = colorName
        spools[idx].colorHex = colorHex
        spools[idx].extraColorHexes = extraColorHexes
        spools[idx].brand = brand
        spools[idx].subtype = subtype
        spools[idx].netWeightGrams = netWeightGrams
        spools[idx].nozzleTempMin = nozzleTempMin
        spools[idx].nozzleTempMax = nozzleTempMax
        spools[idx].costPerKg = costPerKg
        spools[idx].category = category
        spools[idx].note = note

        guard isLive, let client, let bbID = bambuddyID(spoolID) else { return }
        let rgba = colorHex.replacingOccurrences(of: "#", with: "").uppercased() + "FF"
        let update = BambuddySpoolUpdateBody(
            material: material,
            subtype: subtype,
            colorName: colorName,
            rgba: rgba,
            extraColors: Self.formatExtraColors(extraColorHexes),
            brand: brand,
            labelWeight: netWeightGrams,
            slicerFilament: nil,
            nozzleTempMin: nozzleTempMin,
            nozzleTempMax: nozzleTempMax,
            costPerKg: costPerKg,
            category: category,
            note: note
        )
        Task {
            do {
                try await client.updateSpool(spoolID: bbID, update)
                await refresh()
            } catch {
                connectionStatus = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
}
