import SwiftUI
import Observation
import WidgetKit
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
    /// Spools Bambuddy has archived (soft-deleted), kept separately so they stay out of every
    /// count, filter and AMS lookup that `spools` feeds, but can still be listed, restored or
    /// deleted from the inventory's Archived filter. Without this, the Undo bar was the only way
    /// back from an archive once it had timed out, short of Bambuddy's web UI.
    private(set) var archivedSpools: [Spool] = []
    var config: BambuddyConfig
    var connectionStatus: ConnectionStatus = .notConfigured
    var grantedPermissions: Set<String> = []
    var isRefreshing = false

    /// Set once resolved (see `resolvePendingDeepLink()`) — `MonitorView` observes this to push
    /// straight to that printer's detail screen instead of leaving people on the printer list.
    /// Apple's Live Activity guidance: "Take people directly to related details and actions —
    /// don't make them navigate to find relevant information."
    var pendingDeepLinkPrinterID: String?
    /// Set by `handleDeepLink` when the link arrives before `printers` is populated yet — a cold
    /// launch straight from the Live Activity hits this every time, since the deep link and the
    /// first refresh race. Re-resolved after every `printers` assignment below.
    private var pendingDeepLinkNormalizedID: String?

    private var locationNames: [Int: String] = [:]

    /// Bambuddy's curated hex->name color catalog, used to resolve a spool's display name when
    /// its own `color_name` is missing or unpresentable — see `mapSpool`. Fetched once (guarded
    /// by emptiness, not a one-shot flag) rather than on every refresh: it's curated, essentially
    /// static data, and re-fetching a small never-changing map every 30s would be pure waste. The
    /// emptiness check also means a first attempt that failed (offline, still connecting) is
    /// retried on the next refresh instead of being stuck cacheless for the rest of the session.
    private var colorCatalog: [String: String] = [:]

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

    /// True whenever `printers`/`spools` hold `MockData` rather than the user's own — which now
    /// only happens with no server configured. Drives the `DemoDataBanner`, so sample printers are
    /// never mistaken for real ones.
    ///
    /// A configured server that can't be reached used to fall back to demo data too. For a
    /// self-hosted, often LAN-only Bambuddy that is the everyday case of opening the app away from
    /// home, and it replaced the user's real fleet with sample printers — and wrote those sample
    /// printers into the home-screen AMS widget. A configured install now keeps its last real data
    /// and says it's stale instead (`serverUnreachableMessage`).
    private(set) var isShowingDemoData = false

    /// When `printers`/`spools` last came from a successful refresh — for the stale-data banner.
    private(set) var lastSuccessfulRefreshAt: Date?

    /// Non-nil while a configured server can't be reached — the banner text explaining that what's
    /// on screen (if anything) is the last known state, not live.
    var serverUnreachableMessage: String? {
        guard config.isConfigured, case .failed = connectionStatus else { return nil }
        if let lastSuccessfulRefreshAt {
            let age = lastSuccessfulRefreshAt.formatted(.relative(presentation: .named))
            return String(localized: "Couldn't reach your server. Showing data from \(age). Pull to retry.", comment: "Server unreachable banner, with stale data on screen")
        }
        return String(localized: "Couldn't reach your server. Pull to retry, or check it in Settings.", comment: "Server unreachable banner, nothing loaded yet")
    }

    /// The most recent failure of a user-initiated action (pause, light, assign, …), shown as an
    /// alert. Kept separate from `connectionStatus` on purpose: one rejected action — e.g. a 403
    /// because the API key lacks that permission — used to mark the whole app disconnected, which
    /// hid every control and put up the demo-data banner until the next reconnect.
    var actionError: String?

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
        archivedSpools = []
        isShowingDemoData = true
        resolvePendingDeepLink()
        AMSWidgetStore.save(Self.makeAMSSnapshots(printers: printers, spools: spools))
        WidgetCenter.shared.reloadTimelines(ofKind: "AMSWidget")
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
        let statusBeforeCheck = connectionStatus
        connectionStatus = .connecting
        do {
            let me = try await client.me()
            grantedPermissions = Set(me.permissions)
            connectionStatus = .connected(username: me.username)
            lastConnectedUsername = me.username
            await refresh()
            return true
        } catch {
            // A cancelled check says nothing about the server. `.refreshable` cancels its task
            // when the user pulls again (or lets go early), which cancels this in-flight request —
            // treating that as a failure flashed "Couldn't reach your server" over a server that
            // was answering fine. Put back whatever the status was before this check; the next
            // refresh settles it.
            if Self.isCancellation(error) {
                NSLog("NCDEBUG Bambuddy connection check cancelled, restoring status %@", String(describing: statusBeforeCheck))
                connectionStatus = statusBeforeCheck
                return false
            }
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            NSLog("NCDEBUG Bambuddy connection failed: %@", msg)
            connectionStatus = .failed(msg)
            // Keep whatever real data is on screen (see `isShowingDemoData`). Sample data left over
            // from before a server was configured is dropped, though: it would now read as the
            // user's own printers behind an "unreachable" banner.
            if isShowingDemoData {
                printers = []
                spools = []
                archivedSpools = []
                isShowingDemoData = false
            }
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

    /// The refresh cycle currently running, if any, and whether another refresh was asked for
    /// while it ran. Refreshes are triggered from many independent places (the foreground poll,
    /// scenePhase, every action's follow-up, the detail menu, background wakes); running them
    /// concurrently multiplied the request fan-out and let an older response land after a newer
    /// one.
    private var refreshCycle: Task<Void, Never>?
    private var refreshRequestedDuringRun = false

    /// Coalesces concurrent calls: a call made while a cycle is running doesn't start a second one
    /// in parallel — it flags that another pass is wanted and waits for the cycle, which runs
    /// exactly one more pass before finishing to pick up whatever changed in the meantime (e.g.
    /// the action that asked for it).
    ///
    /// The follow-up pass lives *inside* the cycle task, and every caller awaits that one task
    /// once. The first version kept the rerun loop in the first caller and had later callers wait
    /// with `while let running = refreshTask { await running.value }` — but awaiting an
    /// already-finished task returns without suspending, so a waiter spun on the main actor
    /// forever and the first caller never got back on to clear `refreshTask`. Any two overlapping
    /// refreshes (launch + foreground, poll + action) froze the whole UI.
    func refresh() async {
        if let cycle = refreshCycle {
            refreshRequestedDuringRun = true
            await cycle.value
            return
        }
        let cycle = Task {
            repeat {
                refreshRequestedDuringRun = false
                await performRefresh()
            } while refreshRequestedDuringRun
            refreshCycle = nil
        }
        refreshCycle = cycle
        await cycle.value
    }

    private func performRefresh() async {
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
            // Same best-effort shape, but only actually fetched once — see colorCatalog's doc.
            async let colorCatalogTask: [String: String]? = colorCatalog.isEmpty ? try? client.colorCatalogMap() : nil

            let (printerList, spoolList, assignmentList, locationList) = try await (printerDTOs, spoolDTOs, assignmentDTOs, locationDTOs)
            let obico = await obicoTask
            // `try?` above swallows a decoding-shape mismatch (a mismatched response schema)
            // with zero signal beyond an empty result -- exactly what happened when this method
            // decoded the wrong envelope shape and silently left every spool's color-name
            // fallback dead for an entire release. Logged unconditionally (not just on failure)
            // so "it's just always 0" is visible in the device log instead of invisible.
            if let fetchedCatalog = await colorCatalogTask {
                if !fetchedCatalog.isEmpty { colorCatalog = fetchedCatalog }
                NSLog("NCDEBUG color catalog fetch: %d entries (cached total now %d)", fetchedCatalog.count, colorCatalog.count)
            }

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
            resolvePendingDeepLink()

            // The cover render is static for the whole print, so only fetch it once per job
            // rather than on every refresh — the Live Activity manager tells us who already has one.
            let printersNeedingCover = printers.filter {
                $0.state == .printing
                    && !PrintLiveActivityManager.shared.hasCoverImage(printerName: $0.name)
                    && !coverFetchFailedJobs.contains(Self.coverJobKey($0))
            }
            var coverImages: [String: Data] = [:]
            if !printersNeedingCover.isEmpty {
                await withTaskGroup(of: (String, Data?).self) { group in
                    for printer in printersNeedingCover {
                        group.addTask {
                            // The API call itself still needs Bambuddy's real numeric id; only the
                            // dictionary key handed to the Live Activity manager uses the name-based one.
                            let image = await self.printerCoverImage(printerID: printer.id, maxPixelSize: 144)
                            return (Self.coverJobKey(printer), image.flatMap { PrintLiveActivityManager.downscaledCoverImage($0) })
                        }
                    }
                    for await (jobKey, data) in group {
                        guard let printer = printersNeedingCover.first(where: { Self.coverJobKey($0) == jobKey }) else { continue }
                        if let data {
                            coverImages[PrintActivityAttributes.normalizedID(printer.name)] = data
                        } else {
                            // A job with no fetchable (or no budget-fitting) render won't grow one
                            // later; retrying it cost a token mint and an image fetch per refresh.
                            coverFetchFailedJobs.insert(jobKey)
                        }
                    }
                }
            }
            await PrintLiveActivityManager.shared.sync(printers: printers, coverImages: coverImages)

            spools = spoolList
                .filter { $0.archivedAt == nil }
                .map { Self.mapSpool($0, assignment: assignmentsBySpoolID[$0.id], locationNames: locationNames, colorCatalog: colorCatalog) }
            // Newest archive first — Bambuddy's `archived_at` is ISO 8601, so it sorts as a string.
            archivedSpools = spoolList
                .filter { $0.archivedAt != nil }
                .sorted { ($0.archivedAt ?? "") > ($1.archivedAt ?? "") }
                .map { Self.mapSpool($0, assignment: nil, locationNames: locationNames, colorCatalog: colorCatalog) }

            isShowingDemoData = false
            lastSuccessfulRefreshAt = Date()
            // A failed refresh drops connectionStatus to .failed; a later successful one must lift
            // it again, or the unreachable banner would outlive the outage.
            if case .failed = connectionStatus, let username = lastConnectedUsername {
                connectionStatus = .connected(username: username)
            }

            AMSWidgetStore.save(Self.makeAMSSnapshots(printers: printers, spools: spools))
            WidgetCenter.shared.reloadTimelines(ofKind: "AMSWidget")
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            NSLog("NCDEBUG Bambuddy refresh failed: %@", msg)
            connectionStatus = .failed(msg)
        }
    }

    /// Whether an error only means the awaiting task was cancelled, not that a request failed.
    nonisolated private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    /// Identifies one print job for `coverFetchFailedJobs` — a new job on the same printer gets a
    /// fresh attempt.
    nonisolated private static func coverJobKey(_ printer: Printer) -> String {
        "\(printer.id)|\(printer.jobFileName ?? "")"
    }

    private var coverFetchFailedJobs: Set<String> = []
    private var lastConnectedUsername: String?

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

    /// Bambuddy's raw `gcode_state`, deliberately blind to the HMS/offline overlays `mapState`
    /// applies. Nil when there is no usable reading at all, which callers must not treat as "no
    /// job" -- see `Printer.jobPhase`.
    ///
    /// `PAUSE` is its own phase rather than folded into idle: a paused print is still a print, its
    /// Live Activity should stay up, and the label should say so. The relay agrees -- it pushes a
    /// "Paused" stateLabel rather than an `end`.
    private static func mapJobPhase(_ dto: BambuddyStatusDTO?) -> JobPhase? {
        guard let dto, dto.connected else { return nil }
        switch dto.state.uppercased() {
        case "RUNNING", "PRINTING", "PREPARE", "SLICING": return .printing
        case "PAUSE", "PAUSED": return .paused
        default: return .idle
        }
    }

    /// Filters Bambuddy's `stg_cur_name` down to detail actually worth showing alongside
    /// `state.label`: nil input passes through, and a value that just repeats the state label
    /// (e.g. stage 0's "Printing" while `state` is already `.printing`) is suppressed rather than
    /// shown as a redundant subtitle. Everything else — "Purifying the chamber air", "Heating
    /// chamber", "Cooling heatbed", etc. — passes through as real, non-obvious detail.
    private static func stageDetail(_ stgCurName: String?, stateLabel: String) -> String? {
        guard let stgCurName, stgCurName != stateLabel else { return nil }
        return stgCurName
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
        // Bambuddy reports a near-zero remaining_time at print start before it has computed a real
        // estimate, which renders as an "Est. finish" a couple of minutes out on a print with
        // hours left. The relay has rejected these since it first saw one; this is the app side of
        // the same rule, so the two cannot disagree about the same activity's estimate.
        let rawRemaining = status?.remainingTime
        let remaining: Int? = rawRemaining.flatMap { value in
            RemainingTimeTrust.isTrustworthy(remainingMinutes: Double(value), progress: progress) ? value : nil
        }
        let job = state == .printing || state == .paused ? status?.subtaskName : nil

        return Printer(
            id: id,
            name: dto.name,
            model: dto.model,
            imageAssetName: assetName(forModel: dto.model),
            state: state,
            jobPhase: mapJobPhase(status),
            jobFileName: (job?.isEmpty == false) ? job : nil,
            progress: (state == .printing || state == .paused) ? progress : nil,
            etaMinutesRemaining: (state == .printing || state == .paused) ? remaining : nil,
            currentLayer: (state == .printing || state == .paused) ? status?.layerNum : nil,
            totalLayers: (state == .printing || state == .paused) ? status?.totalLayers : nil,
            stageDetail: (state == .printing || state == .paused) ? Self.stageDetail(status?.stgCurName, stateLabel: state.label) : nil,
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
    /// Bambuddy's `rgba` field is 6 hex digits (opaque) or 8 (RRGGBB**AA** — the last byte is
    /// alpha). Anything short of 8 digits is treated as fully opaque.
    private static func parseAlpha(_ rgba: String?) -> Double {
        guard let rgba else { return 1 }
        let clean = rgba.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard clean.count >= 8, let value = UInt8(clean.suffix(2), radix: 16) else { return 1 }
        return Double(value) / 255
    }

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

    /// Resolves a spool's display color name the same way Bambuddy's own web frontend does
    /// (`resolveSpoolColorName` in its `colors.ts`): prefer `color_name` when it reads as an
    /// actual name, fall back to a hex lookup in Bambuddy's curated color catalog otherwise, nil
    /// if neither resolves anything. A spool scanned by RFID sometimes gets a decoded `rgba` with
    /// no matching `color_name` at all, or one that's a raw internal Bambu code like "A06-D0"
    /// (not globally unique across material families, so it's not safe to show as-is) — either
    /// way the hex is still real, and the catalog usually knows a name for it. Bambuddy's web UI
    /// shows "-" when even that fails; callers here fall back further to the material name, since
    /// an empty label reads as more broken in a spool card than a slightly redundant one.
    private static func resolveSpoolColorName(colorName: String?, rgba: String?, catalog: [String: String]) -> String? {
        if let colorName, !colorName.isEmpty, colorName.range(of: #"^[A-Z]\d+-[A-Z]\d+$"#, options: .regularExpression) == nil {
            return colorName
        }
        guard let rgba else { return nil }
        let clean = rgba.trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
        guard clean.count >= 6 else { return nil }
        if clean.count == 8, clean.suffix(2) == "00" { return "Clear" }
        return catalog[String(clean.prefix(6))]
    }

    private static func mapSpool(_ dto: BambuddySpoolDTO, assignment: BambuddyAssignmentDTO?, locationNames: [Int: String], colorCatalog: [String: String]) -> Spool {
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
            colorName: resolveSpoolColorName(colorName: dto.colorName, rgba: dto.rgba, catalog: colorCatalog) ?? dto.material,
            colorHex: "#" + (dto.rgba?.prefix(6).uppercased() ?? "808080"),
            colorAlpha: Self.parseAlpha(dto.rgba),
            extraColorHexes: parseExtraColors(dto.extraColors),
            brand: dto.brand ?? "Unknown",
            remainingPercent: percentRemaining,
            netWeightGrams: dto.labelWeight ?? 1000,
            location: location,
            subtype: dto.subtype,
            effectType: dto.effectType,
            slicerFilamentID: dto.slicerFilament,
            nozzleTempMin: dto.nozzleTempMin,
            nozzleTempMax: dto.nozzleTempMax,
            costPerKg: dto.costPerKg,
            category: dto.category,
            note: dto.note
        )
    }

    static func makeAMSSnapshots(printers: [Printer], spools: [Spool]) -> [PrinterAMSSnapshot] {
        var spoolBySlot: [String: Spool] = [:]
        for spool in spools {
            if case .ams(let printerID, let amsIndex, let trayIndex) = spool.location {
                spoolBySlot["\(printerID)-\(amsIndex)-\(trayIndex)"] = spool
            }
        }

        return printers.compactMap { printer in
            guard !printer.amsUnits.isEmpty else { return nil }
            let unitSnapshots = printer.amsUnits.enumerated().map { position, unit in
                AMSUnitSnapshot(
                    displayName: unit.displayName(position: position),
                    isHighTemp: unit.isHT,
                    trays: unit.trays.map { tray in
                        let key = "\(printer.id)-\(tray.amsIndex)-\(tray.trayIndex)"
                        if let spool = spoolBySlot[key] {
                            return AMSTraySnapshot(
                                colorHex: spool.colorHex,
                                colorAlpha: spool.colorAlpha,
                                extraColorHexes: spool.extraColorHexes,
                                subtype: spool.subtype,
                                effectType: spool.effectType,
                                materialLabel: spool.material
                            )
                        } else if tray.isLoaded {
                            return AMSTraySnapshot(colorHex: tray.rawColorHex, materialLabel: tray.rawMaterialLabel)
                        } else {
                            return AMSTraySnapshot(colorHex: nil, materialLabel: nil)
                        }
                    }
                )
            }
            return PrinterAMSSnapshot(
                printerName: printer.name,
                stateLabel: printer.state.label,
                isPrinting: printer.state == .printing,
                amsUnits: unitSnapshots
            )
        }
    }

    private func bambuddyID(_ localID: String) -> Int? {
        guard localID.hasPrefix("bb-") else { return nil }
        return Int(localID.dropFirst(3))
    }

    // MARK: - Camera

    /// Last camera-snapshot failure per printer (keyed by local ID), so the UI can show *why*
    /// a live feed isn't loading instead of silently falling back to a placeholder icon.
    private(set) var cameraErrors: [String: String] = [:]

    /// Only writes when the value actually changes: every camera view reads this dictionary, and
    /// an `@Observable` property invalidates its readers on every assignment — clearing an
    /// already-nil entry on each successful frame redrew every camera view every few seconds.
    private func setCameraError(_ message: String?, for printerID: String) {
        guard cameraErrors[printerID] != message else { return }
        cameraErrors[printerID] = message
    }

    /// Camera stream tokens are shared by every camera view instead of minted per frame, which
    /// doubled the request count of every poll (mint + fetch) for every visible camera. Reused for
    /// at most `streamTokenMaxAge`, and re-minted immediately if the server rejects one — the API
    /// documents no expiry, so the age cap is a conservative guess, not a known lifetime.
    private var streamTokenTask: Task<String, Error>?
    private var streamTokenMintedAt: Date?
    private static let streamTokenMaxAge: TimeInterval = 30

    private func streamToken(using client: BambuddyAPIClient, forceFresh: Bool = false) async throws -> String {
        if !forceFresh, let task = streamTokenTask, let mintedAt = streamTokenMintedAt,
           Date().timeIntervalSince(mintedAt) < Self.streamTokenMaxAge {
            if let token = try? await task.value { return token }
        }
        let task = Task { try await client.cameraStreamToken() }
        streamTokenTask = task
        streamTokenMintedAt = Date()
        do {
            return try await task.value
        } catch {
            // Never cache a failure.
            if streamTokenTask == task { streamTokenTask = nil; streamTokenMintedAt = nil }
            throw error
        }
    }

    /// Fetches with the shared stream token, retrying once with a fresh one if the server
    /// rejects it as expired/invalid.
    private func fetchWithStreamToken(using client: BambuddyAPIClient, _ fetch: (String) async throws -> Data) async throws -> Data {
        do {
            return try await fetch(try await streamToken(using: client))
        } catch BambuddyAPIError.http(let code, _) where code == 401 || code == 403 {
            return try await fetch(try await streamToken(using: client, forceFresh: true))
        }
    }

    /// Fetches one live snapshot for a printer's chamber camera, decoded off the main thread and
    /// downsampled to `maxPixelSize` (the longest edge the caller actually displays). Full-size
    /// camera frames were decoded on the main thread every few seconds just to fill a 60pt
    /// thumbnail.
    func cameraSnapshot(printerID: String, maxPixelSize: CGFloat) async -> UIImage? {
        guard let client, let bbID = bambuddyID(printerID) else {
            setCameraError(String(localized: "Not connected to a server."), for: printerID)
            return nil
        }
        do {
            let data = try await fetchWithStreamToken(using: client) { token in
                try await client.cameraSnapshotData(printerID: bbID, token: token)
            }
            guard let image = await ImageDownsampling.image(from: data, maxPixelSize: maxPixelSize) else {
                setCameraError(String(localized: "Server sent \(data.count) bytes that aren't a decodable image."), for: printerID)
                return nil
            }
            setCameraError(nil, for: printerID)
            return image
        } catch {
            setCameraError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, for: printerID)
            return nil
        }
    }

    /// Fetches the rendered plate preview (angled 3D view) for a printer's current or most
    /// recently finished job. Unlike `cameraSnapshot`, no stream token — see
    /// `BambuddyAPIClient.coverImageData`. `maxPixelSize` nil keeps full resolution (the zoomable
    /// viewer wants it).
    func printerCoverImage(printerID: String, maxPixelSize: CGFloat? = nil) async -> UIImage? {
        guard let client, let bbID = bambuddyID(printerID) else { return nil }
        do {
            let data = try await client.coverImageData(printerID: bbID)
            return await ImageDownsampling.image(from: data, maxPixelSize: maxPixelSize)
        } catch {
            return nil
        }
    }

    // MARK: - Actions

    /// Runs one user-initiated server action.
    ///
    /// - Demo data: only `localChange` runs, so the sample UI stays interactive.
    /// - Configured but not currently connected: nothing changes locally (an optimistic change
    ///   would just be a lie nothing ever sends) and the user is told why.
    /// - Otherwise: `localChange` is applied optimistically, the request is sent, and on success
    ///   the state is refreshed if `refreshAfter`. On failure the error goes to `actionError` —
    ///   never `connectionStatus`, see its doc — and a refresh restores the server's real state
    ///   in place of the optimistic change.
    private func performAction(
        refreshAfter: Bool = true,
        localChange: () -> Void = {},
        _ operation: @escaping (BambuddyAPIClient) async throws -> Void
    ) {
        if isShowingDemoData {
            localChange()
            return
        }
        guard isLive, let client else {
            actionError = String(localized: "Not connected to your server. Pull to refresh and try again.")
            return
        }
        localChange()
        Task {
            do {
                try await operation(client)
                if refreshAfter { await refresh() }
            } catch {
                actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await refresh()
            }
        }
    }

    // MARK: - Printer controls

    func togglePause(_ printerID: String) {
        guard let idx = printers.firstIndex(where: { $0.id == printerID }), let bbID = bambuddyID(printerID) ?? (isShowingDemoData ? 0 : nil) else { return }
        let wasPrinting = printers[idx].state == .printing
        performAction(localChange: { self.printers[idx].state = wasPrinting ? .paused : .printing }) { client in
            if wasPrinting { try await client.pause(printerID: bbID) } else { try await client.resume(printerID: bbID) }
        }
    }

    func stop(_ printerID: String) {
        guard let idx = printers.firstIndex(where: { $0.id == printerID }), let bbID = bambuddyID(printerID) ?? (isShowingDemoData ? 0 : nil) else { return }
        performAction(localChange: {
            self.printers[idx].state = .idle
            self.printers[idx].jobFileName = nil
            self.printers[idx].progress = nil
            self.printers[idx].etaMinutesRemaining = nil
        }) { client in
            try await client.stop(printerID: bbID)
        }
    }

    func toggleLight(_ printerID: String) {
        guard let idx = printers.firstIndex(where: { $0.id == printerID }), let bbID = bambuddyID(printerID) ?? (isShowingDemoData ? 0 : nil) else { return }
        let newValue = !printers[idx].lightOn
        performAction(refreshAfter: false, localChange: { self.printers[idx].lightOn = newValue }) { client in
            try await client.setChamberLight(printerID: bbID, on: newValue)
        }
    }

    func toggleSmartPlug(_ printerID: String) {
        guard let idx = printers.firstIndex(where: { $0.id == printerID }), let plug = printers[idx].smartPlug else { return }
        let newValue = !plug.isOn
        performAction(refreshAfter: false, localChange: { self.printers[idx].smartPlug?.isOn = newValue }) { client in
            try await client.setSmartPlug(plugID: plug.id, on: newValue)
        }
    }

    func homeAxes(_ printerID: String) {
        guard let bbID = bambuddyID(printerID) else { return }
        performAction(refreshAfter: false) { client in
            try await client.homeAxes(printerID: bbID)
        }
    }

    func clearPlate(_ printerID: String) {
        guard let idx = printers.firstIndex(where: { $0.id == printerID }), let bbID = bambuddyID(printerID) ?? (isShowingDemoData ? 0 : nil) else { return }
        performAction(localChange: { self.printers[idx].awaitingPlateClear = false }) { client in
            try await client.clearPlate(printerID: bbID)
        }
    }

    /// Deep link into Bambuddy's own web UI for this printer's live camera page.
    func webCameraURL(printerID: String) -> URL? {
        guard let serverURL = config.serverURL, let bbID = bambuddyID(printerID) else { return nil }
        return serverURL.appendingPathComponent("camera/\(bbID)")
    }

    // MARK: - Deep linking

    /// Resolves the Live Activity's `nozzlecast://printer/<normalized-name>` link (see
    /// `PrintActivityAttributes.normalizedID`, the same key the widget and NSE use) to an actual
    /// printer and stashes it for `MonitorView` to push to.
    func handleDeepLink(printerNormalizedID: String) {
        pendingDeepLinkNormalizedID = printerNormalizedID
        resolvePendingDeepLink()
    }

    private func resolvePendingDeepLink() {
        guard let normalizedID = pendingDeepLinkNormalizedID,
              let printer = printers.first(where: { PrintActivityAttributes.normalizedID($0.name) == normalizedID })
        else { return }
        pendingDeepLinkPrinterID = printer.id
        pendingDeepLinkNormalizedID = nil
    }

    // MARK: - AMS assignment

    func assign(spoolID: String, toPrinter printerID: String, amsIndex: Int, trayIndex: Int) {
        let bbPrinterID = bambuddyID(printerID) ?? 0
        let bbSpoolID = bambuddyID(spoolID) ?? 0
        guard isShowingDemoData || (bambuddyID(printerID) != nil && bambuddyID(spoolID) != nil) else { return }
        performAction(localChange: {
            for i in self.printers.indices {
                for t in self.printers[i].amsUnits.indices {
                    for s in self.printers[i].amsUnits[t].trays.indices where self.printers[i].amsUnits[t].trays[s].spoolID == spoolID {
                        self.printers[i].amsUnits[t].trays[s].spoolID = nil
                    }
                }
            }
            guard let idx = self.printers.firstIndex(where: { $0.id == printerID }),
                  let unitIdx = self.printers[idx].amsUnits.firstIndex(where: { $0.index == amsIndex }),
                  let trayIdx = self.printers[idx].amsUnits[unitIdx].trays.firstIndex(where: { $0.trayIndex == trayIndex }) else { return }
            self.printers[idx].amsUnits[unitIdx].trays[trayIdx].spoolID = spoolID
            if let sIdx = self.spools.firstIndex(where: { $0.id == spoolID }) {
                self.spools[sIdx].location = .ams(printerID: printerID, amsIndex: amsIndex, trayIndex: trayIndex)
            }
        }) { client in
            try await client.assignSpool(spoolID: bbSpoolID, printerID: bbPrinterID, amsID: amsIndex, trayID: trayIndex)
        }
    }

    func unassign(printerID: String, amsIndex: Int, trayIndex: Int) {
        guard let idx = printers.firstIndex(where: { $0.id == printerID }),
              let unitIdx = printers[idx].amsUnits.firstIndex(where: { $0.index == amsIndex }),
              let trayIdx = printers[idx].amsUnits[unitIdx].trays.firstIndex(where: { $0.trayIndex == trayIndex }),
              let bbPrinterID = bambuddyID(printerID) ?? (isShowingDemoData ? 0 : nil) else { return }
        let spoolID = printers[idx].amsUnits[unitIdx].trays[trayIdx].spoolID
        performAction(localChange: {
            self.printers[idx].amsUnits[unitIdx].trays[trayIdx].spoolID = nil
            if let spoolID, let sIdx = self.spools.firstIndex(where: { $0.id == spoolID }) {
                self.spools[sIdx].location = .storage(name: nil)
            }
        }) { client in
            try await client.unassign(printerID: bbPrinterID, amsID: amsIndex, trayID: trayIndex)
        }
    }

    func rereadRFID(printerID: String, amsIndex: Int, trayIndex: Int) {
        guard let bbPrinterID = bambuddyID(printerID) else { return }
        performAction { client in
            try await client.rereadRFID(printerID: bbPrinterID, amsID: amsIndex, trayID: trayIndex)
        }
    }

    // MARK: - Inventory

    @discardableResult
    func addSpool(material: String, colorName: String, colorHex: String, brand: String, netWeightGrams: Int) -> Spool {
        let spool = Spool(
            id: isShowingDemoData ? "mock-spool-\(UUID().uuidString)" : "pending-\(UUID().uuidString)",
            material: material,
            colorName: colorName,
            colorHex: colorHex,
            brand: brand,
            remainingPercent: 100,
            netWeightGrams: netWeightGrams,
            location: .storage(name: nil)
        )
        let rgba = colorHex.replacingOccurrences(of: "#", with: "").uppercased() + "FF"
        // The pending placeholder is replaced by the real record on the follow-up refresh — or,
        // if creation failed, dropped by the failure path's own refresh.
        performAction(localChange: { self.spools.insert(spool, at: 0) }) { client in
            _ = try await client.createSpool(material: material, colorName: colorName, rgba: rgba, brand: brand, labelWeight: netWeightGrams)
        }
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
        guard let idx = spools.firstIndex(where: { $0.id == spoolID }),
              let bbID = bambuddyID(spoolID) ?? (isShowingDemoData ? 0 : nil) else { return }
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
        performAction(localChange: {
            self.spools[idx].material = material
            self.spools[idx].colorName = colorName
            self.spools[idx].colorHex = colorHex
            self.spools[idx].extraColorHexes = extraColorHexes
            self.spools[idx].brand = brand
            self.spools[idx].subtype = subtype
            self.spools[idx].netWeightGrams = netWeightGrams
            self.spools[idx].nozzleTempMin = nozzleTempMin
            self.spools[idx].nozzleTempMax = nozzleTempMax
            self.spools[idx].costPerKg = costPerKg
            self.spools[idx].category = category
            self.spools[idx].note = note
        }) { client in
            _ = try await client.updateSpool(spoolID: bbID, update)
        }
    }

    // MARK: - Archive / delete

    /// The spool most recently archived from this device, for the inventory screen's Undo bar.
    /// Cleared by `restoreArchivedSpool()`, by the bar timing out, or by the next archive.
    var recentlyArchivedSpool: Spool?

    func archivedSpool(_ id: String) -> Spool? {
        archivedSpools.first { $0.id == id }
    }

    /// Takes a spool out of every local slot and both inventory lists — what archiving and
    /// deleting look like on screen until the follow-up refresh confirms it.
    private func removeSpoolLocally(_ spoolID: String) {
        spools.removeAll { $0.id == spoolID }
        archivedSpools.removeAll { $0.id == spoolID }
        for i in printers.indices {
            for u in printers[i].amsUnits.indices {
                for t in printers[i].amsUnits[u].trays.indices where printers[i].amsUnits[u].trays[t].spoolID == spoolID {
                    printers[i].amsUnits[u].trays[t].spoolID = nil
                }
            }
        }
    }

    /// Archives a spool (Bambuddy's soft delete). It moves from the inventory to the Archived
    /// filter, and the Undo bar offers `restoreArchivedSpool()` for a few seconds.
    func archiveSpool(_ spoolID: String) {
        guard let spool = spool(spoolID), let bbID = bambuddyID(spoolID) ?? (isShowingDemoData ? 0 : nil) else { return }
        performAction(localChange: {
            self.removeSpoolLocally(spoolID)
            self.archivedSpools.insert(spool, at: 0)
            self.recentlyArchivedSpool = spool
        }) { client in
            try await client.archiveSpool(spoolID: bbID)
        }
    }

    /// Brings an archived spool back into the inventory.
    func restoreSpool(_ spoolID: String) {
        guard let spool = archivedSpool(spoolID), let bbID = bambuddyID(spoolID) ?? (isShowingDemoData ? 0 : nil) else { return }
        if recentlyArchivedSpool?.id == spoolID { recentlyArchivedSpool = nil }
        performAction(localChange: {
            self.archivedSpools.removeAll { $0.id == spoolID }
            if !self.spools.contains(where: { $0.id == spoolID }) { self.spools.insert(spool, at: 0) }
        }) { client in
            try await client.restoreSpool(spoolID: bbID)
        }
    }

    /// Undoes the most recent `archiveSpool`, from the Undo bar.
    func restoreArchivedSpool() {
        guard let spool = recentlyArchivedSpool else { return }
        restoreSpool(spool.id)
    }

    /// Permanently deletes a spool, active or archived. The UI must confirm before calling this —
    /// there is no undo.
    func deleteSpool(_ spoolID: String) {
        guard spool(spoolID) != nil || archivedSpool(spoolID) != nil,
              let bbID = bambuddyID(spoolID) ?? (isShowingDemoData ? 0 : nil) else { return }
        if recentlyArchivedSpool?.id == spoolID { recentlyArchivedSpool = nil }
        performAction(localChange: { self.removeSpoolLocally(spoolID) }) { client in
            try await client.deleteSpool(spoolID: bbID)
        }
    }
}
