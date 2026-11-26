import os
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
    var printers: [Printer] = [] {
        didSet { rebuildPrintersIndex() }
    }
    private(set) var printersByID: [String: Printer] = [:]

    var spools: [Spool] = [] {
        didSet { rebuildSpoolsIndex() }
    }
    private(set) var spoolsByID: [String: Spool] = [:]

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

    init(config: BambuddyConfig, autoConnect: Bool = true) {
        self.config = config
        printThumbnailCache.countLimit = 120
        printThumbnailCache.totalCostLimit = 30 * 1024 * 1024
        coverCache.countLimit = 40
        coverCache.totalCostLimit = 20 * 1024 * 1024
        if config.isConfigured {
            connectionStatus = .connecting
            if autoConnect {
                Task { await testConnectionAndRefresh() }
            }
        } else {
            loadMockData()
        }
    }

    private func rebuildPrintersIndex() {
        var index: [String: Printer] = [:]
        index.reserveCapacity(printers.count)
        for printer in printers where index[printer.id] == nil {
            index[printer.id] = printer
        }
        printersByID = index
    }

    private func rebuildSpoolsIndex() {
        var index: [String: Spool] = [:]
        index.reserveCapacity(spools.count)
        for spool in spools where index[spool.id] == nil {
            index[spool.id] = spool
        }
        spoolsByID = index
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

    /// Whether to show the "Demo Data" banner over demo data — everywhere except App Store
    /// screenshots, which are taken from demo data (no real printers or spools in them) and
    /// would otherwise all carry the banner. See `ScreenshotMode`.
    var showsDemoDataBanner: Bool { isShowingDemoData && !ScreenshotMode.isActive }

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
        return BambuddyAPIClient(baseURL: url, apiKey: config.apiKey, inventory: inventoryBackend)
    }

    /// Which inventory the server is serving — Bambuddy's own, or Spoolman through Bambuddy's
    /// proxy. Re-detected periodically on refresh, so flipping Bambuddy's Spoolman switch is
    /// followed without any setting in the app; every spool and slot-assignment request goes
    /// wherever this says. Nothing in the UI changes with it beyond hiding the edit fields
    /// Spoolman can't store (`EditSpoolSheet`).
    private(set) var inventoryBackend: InventoryBackend = .builtIn

    func loadMockData() {
        cachedMetadataServerKey = nil
        resetServerScopedCaches()
        printers = MockData.makePrinters()
        // Demo spools carry a percentage rather than weights; at or under 20% counts as low.
        spools = MockData.makeSpools().map { spool in
            var spool = spool
            spool.isLowStock = spool.remainingPercent <= 20
            return spool
        }
        archivedSpools = []
        queue = MockData.makeQueue()
        printHistory = Self.markingVerdictEligibility(MockData.makePrintHistory())
        printHistoryTotal = printHistory.count
        isShowingDemoData = true
        resolvePendingDeepLink()
        saveAMSWidgetIfNeeded()
        savePrintStatusWidget()
        if ScreenshotMocks.isActive {
            Task { await startScreenshotLiveActivities() }
        }
    }

    /// Screenshot mode: Live Activities for the demo printers that are printing, with their mock
    /// covers, the way a refresh starts them for real ones.
    private func startScreenshotLiveActivities() async {
        let includeContentState = !RelayConfigStore.isConfigured
        var coverImages: [String: Data] = [:]
        for printer in printers where printer.state == .printing {
            guard let render = ScreenshotMocks.coverData(job: printer.jobFileName) else { continue }
            let id = PrintActivityAttributes.normalizedID(printer.name)
            if case .saved(let contentState) = await Self.processAndSaveCover(
                render: render,
                printerID: id,
                jobName: printer.jobFileName,
                includeContentState: includeContentState
            ), let contentState {
                coverImages[id] = contentState
            }
        }
        await PrintLiveActivityManager.shared.sync(printers: printers, coverImages: coverImages)
    }

    func printer(_ id: String) -> Printer? { printersByID[id] }
    func printerName(_ id: String) -> String? { printer(id)?.name }
    func amsUnitName(printerID: String, amsIndex: Int) -> String? { printer(printerID)?.amsUnitName(amsIndex: amsIndex) }
    func spool(_ id: String?) -> Spool? {
        guard let id else { return nil }
        return spoolsByID[id]
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
                AppLog.network.debug("Bambuddy connection check cancelled, restoring status \(String(describing: statusBeforeCheck), privacy: .private)")
                connectionStatus = statusBeforeCheck
                return false
            }
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            AppLog.network.error("Bambuddy connection failed: \(msg, privacy: .private)")
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
        // The relay pushes Bambuddy's alerts itself; a second path would deliver each one twice.
        guard let client, !PushSharedStore.relayAlertsActive else { return false }
        guard let providers = try? await client.notificationProviders(),
              let ntfy = providers.first(where: { $0.providerType == "ntfy" && $0.enabled }),
              let server = ntfy.config.server, let topic = ntfy.config.topic
        else { return false }
        PushNotificationManager.shared.subscribe(server: server, topic: topic, authToken: ntfy.config.authToken)
        return true
    }

    /// Asks the relay whether it delivers Bambuddy's alerts (`RelayAlertClient`), and switches the
    /// app's own ntfy/Firebase subscription off when it starts to (on again if it stops), so every
    /// alert arrives exactly once. Keeps the last answer when the relay can't be asked. A relay
    /// without Apple push keys can't push them, so `RelayAlertFeed` fetches them from it instead.
    func updateRelayAlertDelivery() async {
        guard let delivery = await RelayAlertClient.delivery() else { return }
        lastRelayAlertDeliveryCheckAt = Date()
        let wasFeedActive = RelayAlertFeed.isActive
        PushSharedStore.relayAlertsPush = delivery.pushes
        let wasActive = PushSharedStore.relayAlertsActive
        if delivery.active != wasActive {
            PushSharedStore.relayAlertsActive = delivery.active
            if delivery.active {
                PushNotificationManager.shared.unsubscribeCurrent()
            } else {
                await discoverAndSubscribeNtfy()
            }
        }
        if RelayAlertFeed.isActive != wasFeedActive || delivery.active != wasActive {
            BambuddyAlertFeed.scheduleBackgroundCheck()
        }
        // The feed leaves out what this device muted under its own key, which the relay may not
        // have heard yet (a device without an APNs token never registered one).
        if RelayAlertFeed.isActive && !wasFeedActive { await RelayAlertClient.syncMutes() }
    }

    private enum RefreshMode: Int, Comparable {
        case backgroundWake = 0
        case standard = 1
        case userForced = 2

        static func < (lhs: RefreshMode, rhs: RefreshMode) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// The refresh cycle currently running, if any, and whether another refresh was asked for
    /// while it ran. Refreshes are triggered from many independent places (the foreground poll,
    /// scenePhase, every action's follow-up, the detail menu, background wakes); running them
    /// concurrently multiplied the request fan-out and let an older response land after a newer
    /// one.
    private var refreshCycle: Task<Void, Never>?
    private var requestedRefreshMode: RefreshMode?
    @ObservationIgnored private var activeRefreshWaiters: Set<UUID> = []

    /// Coalesces concurrent calls: a call made while a cycle is running doesn't start a second one
    /// in parallel — it flags that another pass is wanted and waits for the cycle, which runs
    /// exactly one more pass before finishing to pick up whatever changed in the meantime (e.g.
    /// the action that asked for it).
    ///
    /// Cancellation-aware: if every active waiter cancels (for instance when a `BGAppRefreshTask`
    /// hits its expiration handler), the underlying `refreshCycle` task is cancelled cleanly.
    func refresh() async {
        await runCoalescedRefresh(mode: .standard)
    }

    /// Lightweight refresh for headless background push wakes: refreshes printers, active spools,
    /// slot assignments, Live Activity covers, Live Activities, and widgets while skipping
    /// non-essential metadata endpoints (`shoppingList`, `archivedSpools`, `locations`,
    /// `lowStockThreshold`, `maintenanceSummary`).
    func refreshForBackgroundWake() async {
        await runCoalescedRefresh(mode: .backgroundWake)
    }

    private func runCoalescedRefresh(mode: RefreshMode) async {
        while !Task.isCancelled {
            if let cycle = refreshCycle {
                if cycle.isCancelled {
                    await cycle.value
                    continue
                }
                if let existing = requestedRefreshMode {
                    requestedRefreshMode = max(existing, mode)
                } else {
                    requestedRefreshMode = mode
                }
                let waiterID = UUID()
                activeRefreshWaiters.insert(waiterID)
                defer { activeRefreshWaiters.remove(waiterID) }
                await withTaskCancellationHandler {
                    await cycle.value
                } onCancel: {
                    Task { @MainActor [weak self] in
                        self?.cancelRefreshWaiter(waiterID)
                    }
                }
                return
            }

            let waiterID = UUID()
            activeRefreshWaiters.insert(waiterID)
            defer { activeRefreshWaiters.remove(waiterID) }

            let cycle = Task {
                var currentMode = mode
                repeat {
                    requestedRefreshMode = nil
                    await performRefresh(mode: currentMode)
                    guard !Task.isCancelled, let nextMode = requestedRefreshMode else { break }
                    currentMode = nextMode
                } while true
                refreshCycle = nil
            }
            refreshCycle = cycle

            await withTaskCancellationHandler {
                await cycle.value
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelRefreshWaiter(waiterID)
                }
            }
            return
        }
    }

    private func cancelRefreshWaiter(_ waiterID: UUID) {
        activeRefreshWaiters.remove(waiterID)
        if activeRefreshWaiters.isEmpty {
            refreshCycle?.cancel()
        }
    }

    private struct InventoryFetchResult: Sendable {
        var backend: InventoryBackend
        var checkedBackend: InventoryBackend?
        var spools: [BambuddySpoolDTO]
        var assignments: [BambuddyAssignmentDTO]
    }

    private enum LowStockThresholdFetchResult: Sendable {
        case skipped
        case fetched(Double?)
        case clientError
        case transientError
    }

    private struct PrinterPollOutput: Sendable {
        var printerID: Int
        var freshStatus: BambuddyStatusDTO?
        var statusToUse: BambuddyStatusDTO?
        var maintenance: BambuddyMaintenanceSummaryDTO?
        var fetchedMaintenance: Bool
        var smartPlug: (info: BambuddySmartPlugSummaryDTO, status: BambuddySmartPlugStatusDTO)?
        var plugMappingUpdate: PlugMappingUpdate
    }

    private enum PlugMappingUpdate: Sendable {
        case unchanged
        case resolved(BambuddySmartPlugSummaryDTO?)
        case invalidate
    }

    private enum CoverSyncOutcome: Sendable {
        case alreadySaved
        case saved(contentState: Data?)
        case failed
    }

    nonisolated private static func fetchInventory(
        client: BambuddyAPIClient,
        currentBackend: InventoryBackend,
        checkBackend: Bool,
        includeArchived: Bool
    ) async throws -> InventoryFetchResult {
        let checkedBackend = checkBackend ? await client.inventoryBackend() : nil
        let backend = checkedBackend ?? currentBackend
        let scopedClient = BambuddyAPIClient(baseURL: client.baseURL, apiKey: client.apiKey, inventory: backend)
        async let spools = scopedClient.spools(includeArchived: includeArchived)
        async let assignments = scopedClient.assignments()
        return try await InventoryFetchResult(
            backend: backend,
            checkedBackend: checkedBackend,
            spools: spools,
            assignments: assignments
        )
    }

    nonisolated private static func fetchLocationsIfNeeded(
        client: BambuddyAPIClient,
        shouldFetch: Bool
    ) async throws -> [BambuddyLocationDTO]? {
        guard shouldFetch else { return nil }
        return try await client.locations()
    }

    nonisolated private static func fetchLowStockThresholdIfNeeded(
        client: BambuddyAPIClient,
        shouldFetch: Bool
    ) async -> LowStockThresholdFetchResult {
        guard shouldFetch else { return .skipped }
        do {
            return .fetched(try await client.lowStockThreshold())
        } catch {
            return BambuddyAPIClient.serverAnswered(error) ? .clientError : .transientError
        }
    }

    @concurrent
    private static func hasSavedCover(printerID: String, jobName: String?) async -> Bool {
        LiveActivityCoverStore.has(printerID: printerID, jobName: jobName)
    }

    @concurrent
    private static func processAndSaveCover(
        render: Data,
        printerID: String,
        jobName: String?,
        includeContentState: Bool
    ) async -> CoverSyncOutcome {
        guard let processed = CoverImageProcessing.process(from: render, includeContentState: includeContentState) else {
            return .failed
        }
        LiveActivityCoverStore.save(
            processed.sharp,
            printerID: printerID,
            jobName: jobName,
            backdropIsLight: processed.backdropIsLight
        )
        return .saved(contentState: processed.contentState)
    }

    private func performRefresh(mode: RefreshMode) async {
        guard let unconfiguredClient = client else { return }
        let serverKey = "\(unconfiguredClient.baseURL.absoluteString)|\(unconfiguredClient.apiKey)"
        resetServerScopedCachesIfNeeded(serverKey: serverKey)

        isRefreshing = true
        defer { isRefreshing = false }

        let now = Date()
        let forceBypassTTL = (mode == .userForced)
        let isBackgroundWake = (mode == .backgroundWake)

        let shouldCheckBackend = forceBypassTTL
            || lastInventoryBackendCheckAt == nil
            || (!isBackgroundWake && now.timeIntervalSince(lastInventoryBackendCheckAt!) >= Self.inventoryBackendTTL)

        let shouldFetchLocations = !isBackgroundWake && (
            forceBypassTTL
                || lastLocationsFetchAt == nil
                || now.timeIntervalSince(lastLocationsFetchAt!) >= Self.locationsTTL
        )

        let shouldFetchLowStockThreshold = !isBackgroundWake && (
            forceBypassTTL
                || lastLowStockThresholdFetchAt == nil
                || now.timeIntervalSince(lastLowStockThresholdFetchAt!) >= Self.lowStockThresholdTTL
        )

        let shouldFetchShoppingList = !isBackgroundWake
        let includeArchivedSpools = !isBackgroundWake
        let shouldFetchColorCatalog = colorCatalog.isEmpty
        let currentBackend = inventoryBackend

        do {
            // Run `inventoryBackend()` concurrently with `printers()` (gating only `spools()` and
            // `assignments()`), and run all slow metadata fetches in the same wave.
            async let printerDTOs = unconfiguredClient.printers()
            async let inventoryTask = Self.fetchInventory(
                client: unconfiguredClient,
                currentBackend: currentBackend,
                checkBackend: shouldCheckBackend,
                includeArchived: includeArchivedSpools
            )
            async let locationsTask = Self.fetchLocationsIfNeeded(client: unconfiguredClient, shouldFetch: shouldFetchLocations)
            async let obicoTask: BambuddyObicoStatusDTO? = try? unconfiguredClient.obicoStatus()
            async let colorCatalogTask: [String: String]? = shouldFetchColorCatalog ? (try? unconfiguredClient.colorCatalogMap()) : nil
            async let lowStockThresholdTask = Self.fetchLowStockThresholdIfNeeded(client: unconfiguredClient, shouldFetch: shouldFetchLowStockThreshold)
            async let shoppingListTask: [BambuddyShoppingListItemDTO]? = shouldFetchShoppingList ? (try? unconfiguredClient.shoppingList()) : nil

            let printerList = try await printerDTOs
            try Task.checkCancellation()

            let statusFetchedAt = Date()
            let fallbackStatuses = lastGoodStatuses
                .filter { statusFetchedAt.timeIntervalSince($0.value.at) < Self.statusReuseWindow }
                .mapValues(\.status)
            let cachedSmartPlugs = smartPlugMappingByPrinterID
            let cachedSmartPlugTimes = smartPlugMappingFetchedAt
            let cachedMaintenance = maintenanceByPrinterID

            let printerOutputs: [Int: PrinterPollOutput] = try await withThrowingTaskGroup(of: PrinterPollOutput.self) { group in
                for p in printerList {
                    let cachedMaint = cachedMaintenance[p.id]
                    let reuseMaintenance: BambuddyMaintenanceSummaryDTO?
                    if isBackgroundWake {
                        reuseMaintenance = cachedMaint?.summary
                    } else if !forceBypassTTL, let cachedMaint, statusFetchedAt.timeIntervalSince(cachedMaint.at) < Self.maintenanceTTL {
                        reuseMaintenance = cachedMaint.summary
                    } else {
                        reuseMaintenance = nil
                    }

                    let cachedPlugEntry = cachedSmartPlugs[p.id]
                    let plugFetchedAt = cachedSmartPlugTimes[p.id]
                    let hasFreshPlugMapping = !forceBypassTTL
                        && cachedPlugEntry != nil
                        && plugFetchedAt.map { statusFetchedAt.timeIntervalSince($0) < Self.smartPlugMappingTTL } == true

                    group.addTask {
                        async let statusTask: BambuddyStatusDTO? = try? unconfiguredClient.status(printerID: p.id)

                        async let maintenanceTask: BambuddyMaintenanceSummaryDTO? = reuseMaintenance == nil && !isBackgroundWake
                            ? (try? unconfiguredClient.maintenanceSummary(printerID: p.id))
                            : nil

                        var smartPlug: (info: BambuddySmartPlugSummaryDTO, status: BambuddySmartPlugStatusDTO)?
                        var plugMappingUpdate: PlugMappingUpdate = .unchanged

                        if !isBackgroundWake {
                            if hasFreshPlugMapping, let cachedSummaryOpt = cachedPlugEntry {
                                if let plugInfo = cachedSummaryOpt {
                                    do {
                                        let plugStatus = try await unconfiguredClient.smartPlugStatus(plugID: plugInfo.id)
                                        smartPlug = (plugInfo, plugStatus)
                                    } catch BambuddyAPIError.http(404, _) {
                                        plugMappingUpdate = .invalidate
                                    } catch {
                                        // Transient smart-plug error; keep the mapping.
                                    }
                                }
                            } else {
                                do {
                                    let plugInfo = try await unconfiguredClient.smartPlug(printerID: p.id)
                                    plugMappingUpdate = .resolved(plugInfo)
                                    if let plugInfo,
                                       let plugStatus = try? await unconfiguredClient.smartPlugStatus(plugID: plugInfo.id) {
                                        smartPlug = (plugInfo, plugStatus)
                                    }
                                } catch BambuddyAPIError.http(404, _) {
                                    plugMappingUpdate = .resolved(nil)
                                } catch {
                                    // Transient error; leave previous mapping unchanged.
                                }
                            }
                        }

                        let fresh = await statusTask
                        if fresh == nil, fallbackStatuses[p.id] != nil {
                            AppLog.network.error("status for printer \(p.id, privacy: .public) failed; showing its last one")
                        }
                        let fetchedMaint = await maintenanceTask
                        let maintenance = reuseMaintenance ?? fetchedMaint
                        return PrinterPollOutput(
                            printerID: p.id,
                            freshStatus: fresh,
                            statusToUse: fresh ?? fallbackStatuses[p.id],
                            maintenance: maintenance,
                            fetchedMaintenance: reuseMaintenance == nil && fetchedMaint != nil,
                            smartPlug: smartPlug,
                            plugMappingUpdate: plugMappingUpdate
                        )
                    }
                }

                var result: [Int: PrinterPollOutput] = [:]
                result.reserveCapacity(printerList.count)
                for try await output in group {
                    result[output.printerID] = output
                }
                return result
            }

            let inventoryResult = try await inventoryTask
            let fetchedLocations = try await locationsTask
            let obico = await obicoTask
            let fetchedCatalog = await colorCatalogTask
            let thresholdResult = await lowStockThresholdTask
            let fetchedShoppingList = await shoppingListTask

            try Task.checkCancellation()

            if shouldCheckBackend {
                if inventoryResult.checkedBackend == nil {
                    let currentBackend = String(describing: self.inventoryBackend)
                    AppLog.network.debug("inventory backend check inconclusive; keeping \(currentBackend, privacy: .private)")
                } else {
                    lastInventoryBackendCheckAt = now
                }
            }
            let backend = inventoryResult.backend

            if let fetchedCatalog {
                if !fetchedCatalog.isEmpty { colorCatalog = fetchedCatalog }
                let cachedCount = self.colorCatalog.count
                AppLog.network.debug("color catalog fetch: \(fetchedCatalog.count, privacy: .public) entries (cached total now \(cachedCount, privacy: .public))")
            }

            let resolvedLocationNames: [Int: String]
            if let fetchedLocations {
                resolvedLocationNames = Dictionary(uniqueKeysWithValues: fetchedLocations.map { ($0.id, $0.name) })
                lastLocationsFetchAt = now
            } else {
                resolvedLocationNames = locationNames
            }

            var resolvedThreshold = self.lowStockThreshold
            switch thresholdResult {
            case .skipped, .transientError:
                break
            case .clientError:
                lastLowStockThresholdFetchAt = now
            case .fetched(let threshold):
                lastLowStockThresholdFetchAt = now
                if let threshold { resolvedThreshold = threshold }
            }

            let resolvedShoppingList = fetchedShoppingList?.map(Self.mapShoppingListItem)

            for (id, output) in printerOutputs {
                if let fresh = output.freshStatus {
                    lastGoodStatuses[id] = (fresh, statusFetchedAt)
                }
                if output.fetchedMaintenance, let maint = output.maintenance {
                    maintenanceByPrinterID[id] = (maint, statusFetchedAt)
                }
                switch output.plugMappingUpdate {
                case .unchanged:
                    break
                case .resolved(let summary):
                    smartPlugMappingByPrinterID[id] = summary
                    smartPlugMappingFetchedAt[id] = statusFetchedAt
                case .invalidate:
                    smartPlugMappingFetchedAt.removeValue(forKey: id)
                }
            }

            var assignmentsByPrinterSlot: [String: BambuddyAssignmentDTO] = [:]
            var assignmentsBySpoolID: [Int: BambuddyAssignmentDTO] = [:]
            for a in inventoryResult.assignments {
                assignmentsByPrinterSlot["\(a.printerId)-\(a.amsId)-\(a.trayId)"] = a
                assignmentsBySpoolID[a.spoolId] = a
            }

            let mappedPrinters = printerList.map { dto in
                let output = printerOutputs[dto.id]
                let extras = PrinterExtras(
                    status: output?.statusToUse,
                    maintenance: output?.maintenance,
                    smartPlug: output?.smartPlug
                )
                var printer = Self.mapPrinter(
                    dto,
                    extras: extras,
                    obico: obico,
                    assignmentsByPrinterSlot: assignmentsByPrinterSlot
                )
                if isBackgroundWake, printer.smartPlug == nil {
                    printer.smartPlug = printersByID[printer.id]?.smartPlug
                }
                return printer
            }

            for printer in mappedPrinters {
                if let job = printer.jobFileName, !job.isEmpty {
                    lastSeenJobNameByPrinterID[printer.id] = job
                }
            }

            let mappedSpools = inventoryResult.spools
                .filter { $0.archivedAt == nil }
                .map {
                    Self.mapSpool(
                        $0,
                        assignment: assignmentsBySpoolID[$0.id],
                        locationNames: resolvedLocationNames,
                        colorCatalog: colorCatalog,
                        lowStockThreshold: resolvedThreshold,
                        backend: backend
                    )
                }

            let mappedArchivedSpools: [Spool]? = includeArchivedSpools
                ? inventoryResult.spools
                    .filter { $0.archivedAt != nil }
                    .sorted { ($0.archivedAt ?? "") > ($1.archivedAt ?? "") }
                    .map {
                        Self.mapSpool(
                            $0,
                            assignment: nil,
                            locationNames: resolvedLocationNames,
                            colorCatalog: colorCatalog,
                            lowStockThreshold: resolvedThreshold,
                            backend: backend
                        )
                    }
                : nil

            // Commit all refreshed domain state cohesively before awaiting cover images or alert feeds.
            if backend != inventoryBackend {
                AppLog.network.debug("inventory backend is now \(String(describing: backend), privacy: .private)")
                inventoryBackend = backend
                // Spool ids belong to the backend they came from; an Undo for a spool archived in
                // the other one would point at the wrong record.
                recentlyArchivedSpool = nil
            }
            locationNames = resolvedLocationNames
            lowStockThreshold = resolvedThreshold
            if let resolvedShoppingList { shoppingList = resolvedShoppingList }
            printers = mappedPrinters
            spools = mappedSpools
            if let mappedArchivedSpools { archivedSpools = mappedArchivedSpools }
            isShowingDemoData = false
            lastSuccessfulRefreshAt = Date()
            // A failed refresh drops connectionStatus to .failed; a later successful one must lift
            // it again, or the unreachable banner would outlive the outage.
            if case .failed = connectionStatus, let username = lastConnectedUsername {
                connectionStatus = .connected(username: username)
            }
            resolvePendingDeepLink()

            // The cover render is static for the whole print, so only fetch it once per job —
            // until the sharp copy for this job is saved. That copy is what the Live Activity
            // shows (it can't fetch anything itself), and this runs on the relay's background
            // wakes too, so a relay-started activity gets it without the app being opened.
            let includeContentState = !RelayConfigStore.isConfigured
            let printingCandidates = mappedPrinters.filter {
                $0.state == .printing && !coverFetchFailedJobs.contains(Self.coverJobKey($0))
            }
            var coverImages: [String: Data] = [:]
            if !printingCandidates.isEmpty {
                await withTaskGroup(of: (Int, CoverSyncOutcome).self) { group in
                    for (index, printer) in printingCandidates.enumerated() {
                        let printerID = printer.id
                        let normalizedID = PrintActivityAttributes.normalizedID(printer.name)
                        let jobName = printer.jobFileName
                        group.addTask {
                            if await Self.hasSavedCover(printerID: normalizedID, jobName: jobName) {
                                return (index, .alreadySaved)
                            }
                            // The API call itself still needs Bambuddy's real numeric id; the Live
                            // Activity side is keyed by the name-based one.
                            guard let render = await self.printerCoverData(printerID: printerID) else {
                                return (index, .failed)
                            }
                            let outcome = await Self.processAndSaveCover(
                                render: render,
                                printerID: normalizedID,
                                jobName: jobName,
                                includeContentState: includeContentState
                            )
                            return (index, outcome)
                        }
                    }
                    for await (index, outcome) in group {
                        let printer = printingCandidates[index]
                        switch outcome {
                        case .alreadySaved:
                            break
                        case .saved(let contentState):
                            if let contentState {
                                coverImages[PrintActivityAttributes.normalizedID(printer.name)] = contentState
                            }
                        case .failed:
                            // A job with no fetchable render won't grow one later; retrying it cost
                            // an image fetch per refresh.
                            coverFetchFailedJobs.insert(Self.coverJobKey(printer))
                        }
                    }
                }
            }
            guard !Task.isCancelled else { return }
            await PrintLiveActivityManager.shared.sync(printers: printers, coverImages: coverImages)
            guard !Task.isCancelled else { return }

            saveAMSWidgetIfNeeded()
            savePrintStatusWidget()

            // No Firebase means no pushed alerts; read them from Bambuddy's log instead.
            // A relay without Apple push keys keeps them for the app to fetch instead.
            if forceBypassTTL
                || lastRelayAlertDeliveryCheckAt == nil
                || Date().timeIntervalSince(lastRelayAlertDeliveryCheckAt!) >= Self.relayAlertDeliveryTTL {
                await updateRelayAlertDelivery()
            }
            guard !Task.isCancelled else { return }
            if RelayAlertFeed.isActive {
                await RelayAlertFeed.check()
            } else if BambuddyAlertFeed.isActive {
                await BambuddyAlertFeed.check(using: unconfiguredClient)
            }
        } catch {
            if Self.isCancellation(error) {
                AppLog.network.debug("Bambuddy refresh cancelled")
                return
            }
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            AppLog.network.error("Bambuddy refresh failed: \(msg, privacy: .private)")
            connectionStatus = .failed(msg)
        }
    }

    private func resetServerScopedCachesIfNeeded(serverKey: String) {
        guard cachedMetadataServerKey != serverKey else { return }
        resetServerScopedCaches()
        cachedMetadataServerKey = serverKey
    }

    private func resetServerScopedCaches() {
        cacheGeneration &+= 1
        lastInventoryBackendCheckAt = nil
        lastLowStockThresholdFetchAt = nil
        lastLocationsFetchAt = nil
        smartPlugMappingByPrinterID = [:]
        smartPlugMappingFetchedAt = [:]
        maintenanceByPrinterID = [:]
        lastRelayAlertDeliveryCheckAt = nil
        colorCatalog = [:]
        locationNames = [:]
        coverFetchFailedJobs = []
        lastGoodStatuses = [:]
        lastSeenJobNameByPrinterID = [:]
        streamTokenTask = nil
        streamTokenMintedAt = nil
        coverCache.removeAllObjects()
        inFlightDisplayCovers = [:]
        inFlightCoverImages = [:]
        printThumbnailCache.removeAllObjects()
        inFlightPrintThumbnails = [:]
        missingPrintThumbnails = [:]
        lastSavedAMSSnapshots = nil
        lastSavedPrintStatusSnapshots = nil
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

    /// Each printer's last status that loaded, and when. One refresh's /status request failing
    /// reuses it, so a single timeout doesn't show a printing printer as Offline with empty AMS
    /// slots — in the app and in the widgets saved from it. Only within `statusReuseWindow`:
    /// a printer whose status keeps failing past that does show Offline.
    private var lastGoodStatuses: [Int: (status: BambuddyStatusDTO, at: Date)] = [:]
    private static let statusReuseWindow: TimeInterval = 120
    private var lastConnectedUsername: String?

    private static let inventoryBackendTTL: TimeInterval = 5 * 60
    private static let lowStockThresholdTTL: TimeInterval = 5 * 60
    private static let locationsTTL: TimeInterval = 5 * 60
    private static let smartPlugMappingTTL: TimeInterval = 5 * 60
    private static let maintenanceTTL: TimeInterval = 3 * 60
    private static let relayAlertDeliveryTTL: TimeInterval = 2 * 60

    @ObservationIgnored private var cachedMetadataServerKey: String?
    @ObservationIgnored private var cacheGeneration: UInt64 = 0
    @ObservationIgnored private var lastInventoryBackendCheckAt: Date?
    @ObservationIgnored private var lastLowStockThresholdFetchAt: Date?
    @ObservationIgnored private var lastLocationsFetchAt: Date?
    @ObservationIgnored private var smartPlugMappingByPrinterID: [Int: BambuddySmartPlugSummaryDTO?] = [:]
    @ObservationIgnored private var smartPlugMappingFetchedAt: [Int: Date] = [:]
    @ObservationIgnored private var maintenanceByPrinterID: [Int: (summary: BambuddyMaintenanceSummaryDTO, at: Date)] = [:]
    @ObservationIgnored private var lastRelayAlertDeliveryCheckAt: Date?
    @ObservationIgnored private var lastSeenJobNameByPrinterID: [String: String] = [:]
    @ObservationIgnored private var lastSavedAMSSnapshots: [PrinterAMSSnapshot]?
    @ObservationIgnored private var lastSavedPrintStatusSnapshots: [PrintStatusSnapshot]?

    // MARK: - Mapping

    private static func assetName(forModel model: String) -> String? {
        let m = model.uppercased()
        if m.contains("X1C") || m.contains("X1 CARBON") { return "PrinterX1C" }
        if m.contains("X1E") { return "PrinterX1E" }
        if m.contains("P1S") { return "PrinterP1S" }
        if m.contains("P1P") { return "PrinterP1P" }
        if m.contains("P2S") { return "PrinterP2S" }
        if m.contains("H2C") { return "PrinterH2C" }
        if m.contains("H3C") { return "PrinterH3C" }
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

    /// The printer's phase from `gcode_state`, as Bambuddy's printer card labels it
    /// (`getStatusDisplay`): `FINISH` is Finished and `FAILED` is Failed — a failed or cancelled
    /// job's end state, not a fault. HMS alerts deliberately play no part (see `PrinterState`).
    private static func mapState(_ dto: BambuddyStatusDTO?) -> PrinterState {
        guard let dto else { return .offline }
        if !dto.connected { return .offline }
        switch dto.state.uppercased() {
        case "RUNNING", "PRINTING", "PREPARE", "SLICING": return .printing
        case "PAUSE", "PAUSED": return .paused
        case "FINISH", "FINISHED": return .finished
        case "FAILED": return .failed
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
        let state = mapState(status)
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
            activeTrayID: (state == .printing || state == .paused) ? status?.trayNow.flatMap { $0 == 255 ? nil : $0 } : nil,
            lacksDeveloperMode: status?.developerMode == false,
            nozzles: nozzles,
            nozzleRack: nozzleRack,
            totalPrintHours: extras.maintenance?.totalPrintHours,
            maintenanceOK: extras.maintenance.map { $0.dueCount == 0 && $0.warningCount == 0 },
            maintenanceTasks: (extras.maintenance?.maintenanceItems ?? []).filter(\.enabled).map(Self.mapMaintenanceTask).sorted(by: Self.isMoreUrgent),
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
    /// Bambuddy's RRGGBBAA for a "#RRGGBB" colour and a 0...1 alpha — `parseAlpha`'s inverse.
    static func rgba(hex: String, alpha: Double) -> String {
        let byte = UInt8((min(max(alpha, 0), 1) * 255).rounded())
        return hex.replacingOccurrences(of: "#", with: "").uppercased() + String(format: "%02X", byte)
    }

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
    ///
    /// `colorNameIsSynthesized` (Spoolman mode, where `colorName` is really the filament's name)
    /// demotes the name to a last resort behind the catalog — Bambuddy's own rule, so a Spoolman
    /// spool reads the same in the app as in its web UI.
    private static func resolveSpoolColorName(colorName: String?, rgba: String?, catalog: [String: String], colorNameIsSynthesized: Bool = false) -> String? {
        let readable: String? = {
            guard let colorName, !colorName.isEmpty,
                  colorName.range(of: #"^[A-Z]\d+-[A-Z]\d+$"#, options: .regularExpression) == nil else { return nil }
            return colorName
        }()
        if let readable, !colorNameIsSynthesized { return readable }
        if let rgba {
            let clean = rgba.trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
            if clean.count >= 6 {
                if clean.count == 8, clean.suffix(2) == "00" { return "Clear" }
                if let mapped = catalog[String(clean.prefix(6))] { return mapped }
            }
        }
        return readable
    }

    private static func mapSpool(_ dto: BambuddySpoolDTO, assignment: BambuddyAssignmentDTO?, locationNames: [Int: String], colorCatalog: [String: String], lowStockThreshold: Double, backend: InventoryBackend = .builtIn) -> Spool {
        // Bambuddy's own "Low Stock" count, exactly: unrounded remaining percent of the label
        // weight (0 for a spool with no label weight) below the spool's own threshold, else the
        // server-wide one. Archived spools aren't stock.
        let isLowStock: Bool = {
            guard dto.archivedAt == nil else { return false }
            let label = Double(dto.labelWeight ?? 0)
            let remaining = max(0, label - (dto.weightUsed ?? 0))
            let percent = label > 0 ? remaining / label * 100 : 0
            return percent < (dto.lowStockThresholdPct.map(Double.init) ?? lowStockThreshold)
        }()
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
            // Spoolman spools carry a free-text location that Bambuddy maps to one of its own
            // locations when it can; show the text itself when it couldn't.
            let storageText = dto.storageLocation?.trimmingCharacters(in: .whitespaces)
            location = .storage(name: dto.locationId.flatMap { locationNames[$0] } ?? (storageText?.isEmpty == false ? storageText : nil))
        }

        // Bambuddy's built-in inventory records when a spool was archived. Spoolman only has an
        // `archived` flag, and Bambuddy fills `archived_at` from the spool's last use (or its
        // registration) instead — so in that mode the spool is marked archived without a date.
        // An unparseable timestamp still marks the spool archived rather than silently making
        // it look active.
        let archivedAt = dto.archivedAt.map { Self.parseBambuddyTimestamp($0) ?? .distantPast }
        let archivedDateIsKnown = backend == .builtIn && dto.archivedAt.flatMap(Self.parseBambuddyTimestamp) != nil

        return Spool(
            id: "bb-\(dto.id)",
            material: dto.material,
            colorName: resolveSpoolColorName(colorName: dto.colorName, rgba: dto.rgba, catalog: colorCatalog, colorNameIsSynthesized: dto.colorNameIsSynthesized ?? false) ?? dto.material,
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
            note: dto.note,
            archivedAt: archivedAt,
            archivedDateIsKnown: archivedDateIsKnown,
            isLowStock: isLowStock,
            materialNumber: dto.materialNumber.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 },
            suppliers: (dto.suppliers ?? []).map {
                SpoolSupplier(name: $0.supplierName, articleNumber: $0.supplierArticleNumber, pricePerKg: $0.quotedPricePerKg, isPurchaseSource: $0.isPurchaseSource ?? false)
            },
            lastUsedAt: dto.lastUsed.flatMap(Self.parseBambuddyTimestamp),
            hasTag: [dto.tagUid, dto.trayUuid].contains { !($0 ?? "").isEmpty }
        )
    }

    nonisolated private static let iso8601FractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    nonisolated private static let iso8601WholeStyle = Date.ISO8601FormatStyle()

    /// Parses Bambuddy's timestamps, e.g. `2026-09-30T00:29:03.208491` — ISO 8601 with
    /// microseconds and, as served by its Python backend, no UTC offset (these are UTC). Also
    /// accepts the same shape with an offset or without the fractional part, so a format change
    /// on Bambuddy's side degrades to "no date" rather than a crash.
    nonisolated static func parseBambuddyTimestamp(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        let utf8 = raw.utf8
        func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }

        // Detect trailing timezone: "Z", "+HHMM", "-HHMM", "+HH:MM", or "-HH:MM".
        let hasTimezone: Bool = {
            let count = utf8.count
            let end = utf8.endIndex
            let last = utf8[utf8.index(before: end)]
            if last == UInt8(ascii: "Z") { return true }
            if count >= 5 {
                let signIdx = utf8.index(end, offsetBy: -5)
                let sign = utf8[signIdx]
                if (sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-")),
                   isDigit(utf8[utf8.index(after: signIdx)]),
                   isDigit(utf8[utf8.index(signIdx, offsetBy: 2)]),
                   isDigit(utf8[utf8.index(signIdx, offsetBy: 3)]),
                   isDigit(last) {
                    return true
                }
            }
            if count >= 6 {
                let signIdx = utf8.index(end, offsetBy: -6)
                let sign = utf8[signIdx]
                let colonIdx = utf8.index(end, offsetBy: -3)
                if (sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-")),
                   utf8[colonIdx] == UInt8(ascii: ":"),
                   isDigit(utf8[utf8.index(after: signIdx)]),
                   isDigit(utf8[utf8.index(signIdx, offsetBy: 2)]),
                   isDigit(utf8[utf8.index(after: colonIdx)]),
                   isDigit(last) {
                    return true
                }
            }
            return false
        }()

        // Date.ISO8601FormatStyle handles at most millisecond fractions; trim extra digits.
        var normalized = raw
        var hasFraction = false
        if let dotIndex = utf8.firstIndex(of: UInt8(ascii: ".")) {
            hasFraction = true
            let afterDot = utf8.index(after: dotIndex)
            var digitEnd = afterDot
            var digitCount = 0
            var thirdDigitEnd = afterDot
            while digitEnd < utf8.endIndex, isDigit(utf8[digitEnd]) {
                digitEnd = utf8.index(after: digitEnd)
                digitCount += 1
                if digitCount == 3 { thirdDigitEnd = digitEnd }
            }
            if digitCount > 3 {
                let prefix = String(raw[..<thirdDigitEnd])
                let suffix = String(raw[digitEnd...])
                normalized = hasTimezone ? (prefix + suffix) : (prefix + suffix + "Z")
            } else if !hasTimezone {
                normalized = raw + "Z"
            }
        } else if !hasTimezone {
            normalized = raw + "Z"
        }

        if hasFraction, let date = try? iso8601FractionalStyle.parse(normalized) {
            return date
        }
        return try? iso8601WholeStyle.parse(normalized)
    }

    /// One snapshot per printer for the Print Status widget. The content-state fields come from the same
    /// derivation the Live Activity uses, so the widget and the Lock Screen agree.
    /// Whether a printer's job file and a print-history name are the same print: the history
    /// names it without the ".gcode.3mf"/".3mf" the printer reports, and case can differ.
    static func sameJobName(_ a: String, _ b: String) -> Bool {
        func stem(_ name: String) -> String {
            var name = name.lowercased()
            for suffix in [".gcode.3mf", ".3mf", ".gcode"] where name.hasSuffix(suffix) {
                name.removeLast(suffix.count)
                break
            }
            return name.trimmingCharacters(in: .whitespaces)
        }
        return stem(a) == stem(b)
    }

    static func makePrintStatusSnapshots(printers: [Printer], history: [PrintRecord], previous: [PrintStatusSnapshot] = []) -> [PrintStatusSnapshot] {
        printers.map { printer in
            let state = PrintLiveActivityManager.contentState(for: printer, coverImage: nil)
            // Same rule the Live Activity uses to keep an activity alive: a job is loaded (printing or
            // paused). Without a `jobPhase` it falls back to the printer's state: demo printers only
            // set that, and a real printer with no reading is offline, so it still counts as idle.
            let isActive = printer.jobPhase.map(\.isActive) ?? [.printing, .paused].contains(printer.state)
            var lastJobName: String?
            var finishedAt: Date?
            var lastOutcome: PrintStatusSnapshot.Outcome?
            if !isActive {
                let newest = history
                    .filter { $0.printerID == printer.id || $0.printerName == printer.name }
                    .max { ($0.finishedAt ?? $0.startedAt ?? .distantPast) < ($1.finishedAt ?? $1.startedAt ?? .distantPast) }
                // Raw names: LiveActivityCoverStore strips .3mf/.gcode itself when keying covers.
                lastJobName = newest?.name ?? printer.jobFileName
                finishedAt = newest?.finishedAt
                switch newest?.outcome {
                case .completed: lastOutcome = .completed
                case .failed: lastOutcome = .failed
                case .cancelled: lastOutcome = .cancelled
                case .other, nil: lastOutcome = nil
                }
                // No history for this printer (not loaded yet): keep what the last save knew about
                // its last print, as long as it's the same job the printer still reports.
                if newest == nil,
                   let earlier = previous.first(where: { $0.printerID == PrintActivityAttributes.normalizedID(printer.name) && !$0.isActive }),
                   let earlierJob = earlier.lastJobName,
                   printer.jobFileName.map({ Self.sameJobName($0, earlierJob) }) ?? true {
                    lastJobName = earlierJob
                    finishedAt = earlier.finishedAt
                    lastOutcome = earlier.lastOutcome
                }
            }
            return PrintStatusSnapshot(
                printerID: PrintActivityAttributes.normalizedID(printer.name),
                printerName: printer.name,
                stateLabel: state.stateLabel,
                isActive: isActive,
                progress: state.progress,
                jobName: state.jobName,
                startedAt: state.startedAt,
                estimatedEndAt: state.estimatedEndAt,
                currentLayer: state.currentLayer,
                totalLayers: state.totalLayers,
                nozzleTempC: state.nozzleTempC,
                rightNozzleTempC: state.rightNozzleTempC,
                bedTempC: state.bedTempC,
                issueSeverity: state.issueSeverity,
                issueCount: state.issueCount,
                stageDetail: state.stageDetail,
                lastJobName: lastJobName,
                finishedAt: finishedAt,
                lastOutcome: lastOutcome
            )
        }
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
                        let isFeeding = printer.activeTrayID != nil && tray.globalID() == printer.activeTrayID
                        if let spool = spoolBySlot[key] {
                            return AMSTraySnapshot(
                                colorHex: spool.colorHex,
                                colorAlpha: spool.colorAlpha,
                                extraColorHexes: spool.extraColorHexes,
                                subtype: spool.subtype,
                                effectType: spool.effectType,
                                materialLabel: spool.material,
                                isFeeding: isFeeding,
                                colorName: spool.colorName.isEmpty ? nil : spool.colorName,
                                remainingGrams: spool.remainingGrams,
                                remainingFraction: min(max(Double(spool.remainingPercent) / 100, 0), 1),
                                isLow: spool.isLowStock
                            )
                        } else if tray.isLoaded {
                            return AMSTraySnapshot(colorHex: tray.rawColorHex, materialLabel: tray.rawMaterialLabel, isFeeding: isFeeding)
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
    /// Bambuddy issues stream tokens valid for 60 minutes (`create_stream_token`); reuse one for
    /// 50 to stay clear of the expiry edge. A rejected token is still re-minted immediately.
    private static let streamTokenMaxAge: TimeInterval = 50 * 60

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
        if isShowingDemoData, let data = ScreenshotMocks.cameraData(job: printer(printerID)?.jobFileName) {
            return await ImageDownsampling.image(from: data, maxPixelSize: maxPixelSize)
        }
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
            if Self.isCancellation(error) { return nil }
            setCameraError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, for: printerID)
            return nil
        }
    }

    /// Whether the relay composes covers itself (`bg=auto`, relay v1.5.0+). Nil until it's been
    /// asked; false after an older relay refused it, so the app stops asking until it relaunches.
    @ObservationIgnored private var relayComposesCovers: Bool?

    private final class CachedCover: NSObject {
        let image: UIImage
        let isComposed: Bool

        init(image: UIImage, isComposed: Bool) {
            self.image = image
            self.isComposed = isComposed
        }
    }

    @ObservationIgnored private let coverCache = NSCache<NSString, CachedCover>()
    @ObservationIgnored private var inFlightDisplayCovers: [String: Task<(image: UIImage, isComposed: Bool)?, Never>] = [:]
    @ObservationIgnored private var inFlightCoverImages: [String: Task<UIImage?, Never>] = [:]

    nonisolated private static func imageMemoryCost(_ image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return cgImage.bytesPerRow * cgImage.height
        }
        return Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }

    private func coverCacheJobKey(for printerID: String) -> String {
        if let job = printer(printerID)?.jobFileName, !job.isEmpty {
            return job
        }
        let lastJob = lastSeenJobNameByPrinterID[printerID] ?? ""
        let latestHistoryID = printHistory.first(where: { $0.printerID == printerID })?.id ?? ""
        return "\(lastJob)#\(latestHistoryID)"
    }

    /// The cover for showing in a tile `pixelSize` big: composed by the relay to fit it — trimmed
    /// to the model, on the backdrop for its brightness — when it can, else the raw render, for
    /// the caller to put on that backdrop itself (`isComposed` false).
    func displayCover(printerID: String, pixelSize: CGSize) async -> (image: UIImage, isComposed: Bool)? {
        // An idle demo printer shows its last print, fitted the same way.
        if isShowingDemoData,
           let image = ScreenshotMocks.fittedCover(job: printer(printerID)?.jobFileName ?? printHistory.first { $0.printerID == printerID }?.name, pixelSize: pixelSize) {
            return (image, false)
        }
        let sizeKey = "\(Int(pixelSize.width.rounded()))x\(Int(pixelSize.height.rounded()))"
        let rawKey = "\(printerID)|\(coverCacheJobKey(for: printerID))|\(sizeKey)"
        let cacheKey = rawKey as NSString
        if let cached = coverCache.object(forKey: cacheKey) {
            return (cached.image, cached.isComposed)
        }
        if let existingTask = inFlightDisplayCovers[rawKey] {
            return await existingTask.value
        }

        let generation = cacheGeneration
        let task = Task<(image: UIImage, isComposed: Bool)?, Never> { [weak self] in
            guard let self else { return nil }
            defer {
                if self.cacheGeneration == generation {
                    self.inFlightDisplayCovers.removeValue(forKey: rawKey)
                }
            }
            var askRelayForRaw = true
            if self.relayComposesCovers != false, let name = self.printer(printerID)?.name {
                switch await RelayCoverClient.displayCoverImageData(printerName: name, pixelSize: pixelSize) {
                case .image(let data):
                    self.relayComposesCovers = true
                    if let image = await ImageDownsampling.image(from: data, maxPixelSize: nil) {
                        if self.cacheGeneration == generation {
                            self.coverCache.setObject(CachedCover(image: image, isComposed: true), forKey: cacheKey, cost: Self.imageMemoryCost(image))
                        }
                        return (image, true)
                    }
                case .unsupported:
                    self.relayComposesCovers = false
                case .unavailable:
                    // The relay has no cover either way (or no relay); straight to Bambuddy.
                    askRelayForRaw = false
                }
            }
            guard let data = await self.printerCoverData(printerID: printerID, maxPixelSize: max(pixelSize.width, pixelSize.height), askRelay: askRelayForRaw),
                  let image = await ImageDownsampling.image(from: data, maxPixelSize: max(pixelSize.width, pixelSize.height))
            else { return nil }
            if self.cacheGeneration == generation {
                self.coverCache.setObject(CachedCover(image: image, isComposed: false), forKey: cacheKey, cost: Self.imageMemoryCost(image))
            }
            return (image, false)
        }
        inFlightDisplayCovers[rawKey] = task
        return await task.value
    }

    /// Fetches the rendered plate preview (angled 3D view) for a printer's current or most
    /// recently finished job. Unlike `cameraSnapshot`, no stream token — see
    /// `BambuddyAPIClient.coverImageData`. `maxPixelSize` nil keeps full resolution (the zoomable
    /// viewer wants it).
    ///
    /// Asks the relay first when one is configured: it also finds the cover of an HTTPS-dispatched
    /// print or a job name with a "/", which Bambuddy can't (see `RelayCoverClient`). Bambuddy directly is
    /// the fallback.
    func printerCoverImage(printerID: String, maxPixelSize: CGFloat? = nil) async -> UIImage? {
        if isShowingDemoData {
            guard let data = await printerCoverData(printerID: printerID, maxPixelSize: maxPixelSize) else { return nil }
            return await ImageDownsampling.image(from: data, maxPixelSize: maxPixelSize)
        }
        let sizeKey = maxPixelSize.map { "max\(Int($0.rounded()))" } ?? "full"
        let rawKey = "\(printerID)|\(coverCacheJobKey(for: printerID))|\(sizeKey)"
        let cacheKey = rawKey as NSString
        if let cached = coverCache.object(forKey: cacheKey) {
            return cached.image
        }
        if let existingTask = inFlightCoverImages[rawKey] {
            return await existingTask.value
        }

        let generation = cacheGeneration
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            defer {
                if self.cacheGeneration == generation {
                    self.inFlightCoverImages.removeValue(forKey: rawKey)
                }
            }
            guard let data = await self.printerCoverData(printerID: printerID, maxPixelSize: maxPixelSize),
                  let image = await ImageDownsampling.image(from: data, maxPixelSize: maxPixelSize)
            else { return nil }
            if self.cacheGeneration == generation {
                self.coverCache.setObject(CachedCover(image: image, isComposed: false), forKey: cacheKey, cost: Self.imageMemoryCost(image))
            }
            return image
        }
        inFlightCoverImages[rawKey] = task
        return await task.value
    }

    /// The cover render's encoded bytes as served (a PNG with its transparency intact), from the
    /// relay first and Bambuddy directly otherwise — see `printerCoverImage`.
    func printerCoverData(printerID: String, maxPixelSize: CGFloat? = nil, askRelay: Bool = true) async -> Data? {
        if isShowingDemoData, let data = ScreenshotMocks.coverData(job: printer(printerID)?.jobFileName) { return data }
        if askRelay, let name = printer(printerID)?.name,
           let data = await RelayCoverClient.coverImageData(printerName: name, maxPixelSize: maxPixelSize) {
            return data
        }
        guard let client, let bbID = bambuddyID(printerID) else { return nil }
        return try? await client.coverImageData(printerID: bbID)
    }

    /// URL of the printer's live MJPEG camera stream, carrying a (shared, reused) stream token.
    func liveStreamURL(printerID: String) async -> URL? {
        guard let client, let bbID = bambuddyID(printerID),
              let token = try? await streamToken(using: client) else { return nil }
        return client.cameraStreamURL(printerID: bbID, token: token)
    }

    /// Best-effort: tells Bambuddy the in-app live viewer closed (see `stopCameraStream`).
    func stopLiveStream(printerID: String) {
        guard let client, let bbID = bambuddyID(printerID) else { return }
        Task { try? await client.stopCameraStream(printerID: bbID) }
    }

    /// Checks for new alerts without a full refresh — the relay's feed when it can't push them,
    /// else Bambuddy's notification log — for the background app refresh task, which has seconds,
    /// not the minute a refresh can take.
    func checkBambuddyAlerts() async -> Int {
        if RelayAlertFeed.isActive { return await RelayAlertFeed.check() }
        guard let client else { return 0 }
        return await BambuddyAlertFeed.check(using: client)
    }

    /// True while a refresh the user explicitly asked for (the "Refresh Status" menu item) runs —
    /// for a visible indicator. The periodic background refresh deliberately doesn't set it:
    /// a spinner flashing every 30 seconds would be noise.
    private(set) var isUserRefreshing = false

    func refreshFromUser() async {
        isUserRefreshing = true
        defer { isUserRefreshing = false }
        await runCoalescedRefresh(mode: .userForced)
    }

    // MARK: - Actions

    /// Runs one user-initiated server action.
    ///
    /// - Demo data: only `localChange` runs, so the sample UI stays interactive.
    /// - Configured but not currently connected: nothing changes locally (an optimistic change
    ///   would just be a lie nothing ever sends) and the user is told why.
    /// - Otherwise: `localChange` is applied optimistically, the request is sent, and on success
    ///   the state is refreshed if `refreshAfter`. On failure `onFailure` runs, the error goes to
    ///   `actionError` — never `connectionStatus`, see its doc — and a refresh restores the
    ///   server's real state in place of the optimistic change.
    private func performAction(
        refreshAfter: Bool = true,
        localChange: () -> Void = {},
        onFailure: @escaping () -> Void = {},
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
                onFailure()
                actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await refresh()
            }
        }
    }

    // MARK: - Printer controls

    /// Bambuddy answers a print command with success as soon as it has *published* it over MQTT;
    /// a printer that then ignores it (Developer LAN mode off, not always reported by Bambuddy —
    /// confirmed live: a pause returned 200 "Print pause command sent" while the printer stayed
    /// RUNNING) produced no error at all, so the button just silently did nothing. After sending,
    /// watch the printer's reported state for up to `timeout`; if it never gets there, fail with
    /// an explanation instead (which also refreshes the real state over the optimistic one).
    nonisolated private static func confirmPrinterReaches(
        client: BambuddyAPIClient,
        printerID: Int,
        timeout: Duration = .seconds(20),
        _ reached: @Sendable (String) -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(3))
            if let status = try? await client.status(printerID: printerID), reached(status.state.uppercased()) {
                return
            }
        }
        throw PrinterCommandIgnoredError()
    }

    struct PrinterCommandIgnoredError: LocalizedError {
        var errorDescription: String? {
            String(localized: "The printer didn't respond to the command. Developer LAN mode is probably off on the printer; turn it on in its LAN settings to control it from NozzleCast.")
        }
    }

    /// Message for a control the printer will refuse because Developer LAN mode is off — shown if
    /// one is somehow invoked anyway (the UI disables them). See `Printer.lacksDeveloperMode`.
    private func refuseWithoutDeveloperMode(_ printerID: String) -> Bool {
        guard printer(printerID)?.lacksDeveloperMode == true else { return false }
        actionError = String(localized: "Developer LAN mode is off on this printer, so it won't accept this command. Turn it on in the printer's LAN settings.")
        return true
    }

    func togglePause(_ printerID: String) {
        guard !refuseWithoutDeveloperMode(printerID) else { return }
        guard let idx = printers.firstIndex(where: { $0.id == printerID }), let bbID = bambuddyID(printerID) ?? (isShowingDemoData ? 0 : nil) else { return }
        let wasPrinting = printers[idx].state == .printing
        performAction(localChange: { self.printers[idx].state = wasPrinting ? .paused : .printing }) { client in
            if wasPrinting { try await client.pause(printerID: bbID) } else { try await client.resume(printerID: bbID) }
            try await Self.confirmPrinterReaches(client: client, printerID: bbID) { state in
                wasPrinting ? state == "PAUSE" : state == "RUNNING"
            }
        }
    }

    func stop(_ printerID: String) {
        guard !refuseWithoutDeveloperMode(printerID) else { return }
        guard let idx = printers.firstIndex(where: { $0.id == printerID }), let bbID = bambuddyID(printerID) ?? (isShowingDemoData ? 0 : nil) else { return }
        performAction(localChange: {
            self.printers[idx].state = .idle
            self.printers[idx].jobFileName = nil
            self.printers[idx].progress = nil
            self.printers[idx].etaMinutesRemaining = nil
            self.printers[idx].estimatedFinish = nil
        }) { client in
            try await client.stop(printerID: bbID)
            try await Self.confirmPrinterReaches(client: client, printerID: bbID) { state in
                state != "RUNNING" && state != "PAUSE"
            }
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
        guard !refuseWithoutDeveloperMode(printerID) else { return }
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
        // Spoolman mode removes an assignment by the spool's id rather than by its slot.
        let bbSpoolID = spoolID.flatMap(bambuddyID)
        performAction(localChange: {
            self.printers[idx].amsUnits[unitIdx].trays[trayIdx].spoolID = nil
            if let spoolID, let sIdx = self.spools.firstIndex(where: { $0.id == spoolID }) {
                self.spools[sIdx].location = .storage(name: nil)
            }
        }) { client in
            try await client.unassign(printerID: bbPrinterID, amsID: amsIndex, trayID: trayIndex, spoolID: bbSpoolID)
        }
    }

    func rereadRFID(printerID: String, amsIndex: Int, trayIndex: Int) {
        guard !refuseWithoutDeveloperMode(printerID) else { return }
        guard let bbPrinterID = bambuddyID(printerID) else { return }
        performAction { client in
            try await client.rereadRFID(printerID: bbPrinterID, amsID: amsIndex, trayID: trayIndex)
        }
    }

    // MARK: - Inventory

    /// `tag` is the NFC tag a SpoolBuddy read off this spool; it's linked to the new record, so
    /// the next scan of it finds the spool.
    @discardableResult
    func addSpool(material: String, colorName: String, colorHex: String, brand: String, netWeightGrams: Int, tag: (uid: String, trayUUID: String?)? = nil, extras: SpoolCreateExtras = SpoolCreateExtras()) async -> Spool? {
        let placeholder = Spool(
            id: isShowingDemoData ? "mock-spool-\(UUID().uuidString)" : "pending-\(UUID().uuidString)",
            material: material,
            colorName: colorName,
            colorHex: colorHex,
            extraColorHexes: Self.parseExtraColors(extras.extraColors),
            brand: brand,
            remainingPercent: 100,
            netWeightGrams: netWeightGrams,
            location: .storage(name: nil),
            // Shown until the refresh brings the real record, so it reads "PLA Glow" with its
            // finish from the start rather than plain "PLA".
            subtype: extras.subtype,
            effectType: extras.effectType
        )
        if isShowingDemoData {
            spools.insert(placeholder, at: 0)
            return placeholder
        }
        guard isLive, let client else {
            actionError = String(localized: "Not connected to your server. Pull to refresh and try again.")
            return nil
        }
        let rgba = extras.rgba ?? Self.rgba(hex: colorHex, alpha: 1)
        // The pending placeholder is replaced by the real record on the follow-up refresh — or,
        // if creation failed, dropped by the failure path's own refresh.
        spools.insert(placeholder, at: 0)
        do {
            let created = try await client.createSpool(material: material, colorName: colorName, rgba: rgba, brand: brand, labelWeight: netWeightGrams, extras: extras)
            if let tag {
                do {
                    try await client.linkTag(spoolID: created.id, tagUID: tag.uid, trayUUID: tag.trayUUID, origin: .newSpool)
                } catch {
                    let linkError = TagLinkError(underlying: error)
                    actionError = linkError.errorDescription ?? linkError.localizedDescription
                }
            }
            await refresh()
            if let real = spool("bb-\(created.id)") {
                return real
            }
            let mapped = Self.mapSpool(
                created,
                assignment: nil,
                locationNames: locationNames,
                colorCatalog: colorCatalog,
                lowStockThreshold: lowStockThreshold,
                backend: inventoryBackend
            )
            if let idx = spools.firstIndex(where: { $0.id == placeholder.id }) {
                spools[idx] = mapped
            } else {
                spools.insert(mapped, at: 0)
            }
            return mapped
        } catch {
            spools.removeAll { $0.id == placeholder.id }
            actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await refresh()
            return nil
        }
    }

    /// The spool was created but its NFC tag couldn't be linked. Worded so it isn't read as "the
    /// add failed": adding it again would make a second spool.
    struct TagLinkError: LocalizedError {
        var underlying: Error
        var errorDescription: String? {
            let reason = (underlying as? LocalizedError)?.errorDescription ?? underlying.localizedDescription
            return String(localized: "The spool was added, but its tag couldn't be linked (\(reason)). Scan the tag again and link it to that spool instead of adding it again.", comment: "Error after adding a spool whose NFC tag link failed")
        }
    }

    // MARK: - SpoolBuddy

    /// A fresh connection to Bambuddy's event socket, or nil with no server to connect to.
    /// Not started; the caller owns it.
    func makeEventStream() -> BambuddyEventStream? {
        guard !isShowingDemoData, let client else { return nil }
        return BambuddyEventStream(client: client)
    }

    /// Links a scanned NFC tag to an existing spool, so the next scan of it finds the spool.
    /// Bambuddy refuses a tag another active spool already has; that surfaces as `actionError`.
    func linkTag(uid: String, trayUUID: String?, toSpool spoolID: String) {
        guard let bbID = bambuddyID(spoolID) else { return }
        performAction(localChange: {
            if let idx = self.spools.firstIndex(where: { $0.id == spoolID }) { self.spools[idx].hasTag = true }
        }) { client in
            try await client.linkTag(spoolID: bbID, tagUID: uid, trayUUID: trayUUID, origin: .existingSpool)
        }
    }

    /// Nil when the list can't be read (no server, or the key lacks `inventory:read`).
    func spoolBuddyDevices() async -> [BambuddySpoolBuddyDeviceDTO]? {
        guard !isShowingDemoData, let client else { return nil }
        return try? await client.spoolBuddyDevices()
    }

    /// The inventory spool for a Bambuddy spool id, refreshing once if it isn't loaded — a spool
    /// added in Bambuddy since the last refresh.
    func spool(bambuddyID: Int) async -> Spool? {
        if let spool = spool("bb-\(bambuddyID)") { return spool }
        await refresh()
        return spool("bb-\(bambuddyID)")
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
        effectType: String?,
        netWeightGrams: Int,
        nozzleTempMin: Int?,
        nozzleTempMax: Int?,
        costPerKg: Double?,
        category: String?,
        note: String?
    ) {
        guard let idx = spools.firstIndex(where: { $0.id == spoolID }),
              let bbID = bambuddyID(spoolID) ?? (isShowingDemoData ? 0 : nil) else { return }
        // The form edits the colour, not its alpha, so a translucent spool stays translucent.
        let rgba = Self.rgba(hex: colorHex, alpha: spools[idx].colorAlpha)
        let update = BambuddySpoolUpdateBody(
            material: material,
            subtype: subtype,
            colorName: colorName,
            rgba: rgba,
            extraColors: Self.formatExtraColors(extraColorHexes),
            effectType: effectType,
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
            // nil means the form left the effect alone (Spoolman mode); "" clears it.
            if let effectType { self.spools[idx].effectType = effectType.isEmpty ? nil : effectType }
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
            var archived = spool
            archived.archivedAt = Date()
            archived.archivedDateIsKnown = self.inventoryBackend == .builtIn
            self.archivedSpools.insert(archived, at: 0)
            self.recentlyArchivedSpool = spool
        }, onFailure: {
            if self.recentlyArchivedSpool?.id == spoolID {
                self.recentlyArchivedSpool = nil
            }
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
            var restored = spool
            restored.archivedAt = nil
            if !self.spools.contains(where: { $0.id == spoolID }) { self.spools.insert(restored, at: 0) }
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

    // MARK: - Print queue & history

    /// Jobs still to come — the one printing first, then pending jobs in Bambuddy's queue order.
    /// Loaded by `loadPrints()`, not by the periodic `refresh()`: only the Prints tab and the
    /// printer detail's outcome card read it.
    private(set) var queue: [QueuedPrint] = []
    /// Newest first, paged in by `loadMorePrintHistory()`.
    private(set) var printHistory: [PrintRecord] = []
    /// Total records on the server, for knowing when the last page is in.
    private(set) var printHistoryTotal = 0
    /// Bambuddy 1.3.0+ keeps a verdict per print rather than per archive (`BambuddyPrintLogPageDTO.ratesEachPrint`).
    private(set) var serverRatesEachPrint = false
    private(set) var isLoadingPrints = false
    private(set) var hasLoadedPrints = false
    private(set) var printsLoadError: String?

    static let printHistoryPageSize = 40

    @ObservationIgnored private let printThumbnailCache = NSCache<NSString, UIImage>()
    @ObservationIgnored private var inFlightPrintThumbnails: [String: Task<UIImage?, Never>] = [:]
    /// Thumbnails the server didn't have (a print archived without one 404s), and when, so a
    /// scrolling list doesn't ask again every time a row reappears. Only for a minute: a print
    /// that has only just finished gets its thumbnail a little after it shows up in the log.
    @ObservationIgnored private var missingPrintThumbnails: [String: Date] = [:]
    private static let missingPrintThumbnailRetryInterval: TimeInterval = 60

    var hasMorePrintHistory: Bool { printHistory.count < printHistoryTotal }

    /// Reloads the queue and the first page of history.
    func loadPrints() async {
        guard !isShowingDemoData, let client, !isLoadingPrints else { return }
        isLoadingPrints = true
        defer { isLoadingPrints = false }
        do {
            async let queueDTOs = client.queue()
            async let firstPage = client.printLog(limit: Self.printHistoryPageSize, offset: 0)
            let (queueItems, page) = try await (queueDTOs, firstPage)
            queue = mapQueue(queueItems)
            serverRatesEachPrint = page.ratesEachPrint
            printHistory = Self.markingVerdictEligibility(page.items.map(mapPrintRecord), eachPrint: serverRatesEachPrint)
            printHistoryTotal = page.total
            printsLoadError = nil
            hasLoadedPrints = true
            // The refresh saved the widget before this history arrived (the Monitor tab loads it
            // after each refresh), so the last prints only reach the widget from here.
            if !printers.isEmpty { savePrintStatusWidget() }
        } catch {
            printsLoadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func saveAMSWidgetIfNeeded() {
        let next = Self.makeAMSSnapshots(printers: printers, spools: spools)
        let previous = lastSavedAMSSnapshots ?? AMSWidgetStore.load()
        if AMSWidgetStore.lastSavedAt != nil, Self.amsSnapshotsEqual(previous, next) {
            lastSavedAMSSnapshots = previous
            return
        }
        lastSavedAMSSnapshots = next
        AMSWidgetStore.save(next)
        WidgetCenter.shared.reloadTimelines(ofKind: "AMSWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "FilamentStockWidget")
    }

    /// Saves the Print Status widget's snapshots and reloads it when snapshot content changed.
    /// The previous save fills in a printer's last print when the history isn't loaded (a refresh
    /// before `loadPrints`, or a background wake that never loads it), rather than the widget
    /// dropping to a bare "Idle".
    private func savePrintStatusWidget() {
        let previous = lastSavedPrintStatusSnapshots ?? PrintStatusWidgetStore.load()
        let next = Self.makePrintStatusSnapshots(printers: printers, history: printHistory, previous: previous)
        if PrintStatusWidgetStore.lastSavedAt != nil, Self.printStatusSnapshotsEquivalent(previous, next) {
            lastSavedPrintStatusSnapshots = previous
            return
        }
        lastSavedPrintStatusSnapshots = next
        PrintStatusWidgetStore.save(next)
        WidgetCenter.shared.reloadTimelines(ofKind: "PrintStatusWidget")
    }

    nonisolated private static func amsSnapshotsEqual(_ lhs: [PrinterAMSSnapshot], _ rhs: [PrinterAMSSnapshot]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (a, b) in zip(lhs, rhs) {
            guard a.printerName == b.printerName,
                  a.stateLabel == b.stateLabel,
                  a.isPrinting == b.isPrinting,
                  a.amsUnits.count == b.amsUnits.count
            else { return false }
            for (unitA, unitB) in zip(a.amsUnits, b.amsUnits) {
                guard unitA.displayName == unitB.displayName,
                      unitA.isHighTemp == unitB.isHighTemp,
                      unitA.trays.count == unitB.trays.count
                else { return false }
                for (trayA, trayB) in zip(unitA.trays, unitB.trays) {
                    guard trayA.colorHex == trayB.colorHex,
                          trayA.colorAlpha == trayB.colorAlpha,
                          trayA.extraColorHexes == trayB.extraColorHexes,
                          trayA.subtype == trayB.subtype,
                          trayA.effectType == trayB.effectType,
                          trayA.materialLabel == trayB.materialLabel,
                          trayA.isFeeding == trayB.isFeeding,
                          trayA.colorName == trayB.colorName,
                          trayA.remainingGrams == trayB.remainingGrams,
                          trayA.remainingFraction == trayB.remainingFraction,
                          trayA.isLow == trayB.isLow
                    else { return false }
                }
            }
        }
        return true
    }

    nonisolated private static func printStatusSnapshotsEquivalent(_ lhs: [PrintStatusSnapshot], _ rhs: [PrintStatusSnapshot]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (a, b) in zip(lhs, rhs) {
            guard a.printerID == b.printerID,
                  a.printerName == b.printerName,
                  a.stateLabel == b.stateLabel,
                  a.isActive == b.isActive,
                  a.progress == b.progress,
                  a.jobName == b.jobName,
                  a.currentLayer == b.currentLayer,
                  a.totalLayers == b.totalLayers,
                  a.nozzleTempC == b.nozzleTempC,
                  a.rightNozzleTempC == b.rightNozzleTempC,
                  a.bedTempC == b.bedTempC,
                  a.issueSeverity == b.issueSeverity,
                  a.issueCount == b.issueCount,
                  a.stageDetail == b.stageDetail,
                  a.lastJobName == b.lastJobName,
                  a.finishedAt == b.finishedAt,
                  a.lastOutcome == b.lastOutcome
            else { return false }
            if a.isActive {
                if abs(a.startedAt.timeIntervalSince(b.startedAt)) >= 45 { return false }
                switch (a.estimatedEndAt, b.estimatedEndAt) {
                case (nil, nil):
                    break
                case let (ea?, eb?):
                    if abs(ea.timeIntervalSince(eb)) >= 45 { return false }
                default:
                    return false
                }
            }
        }
        return true
    }

    func loadMorePrintHistory() async {
        guard !isShowingDemoData, let client, !isLoadingPrints, hasMorePrintHistory else { return }
        isLoadingPrints = true
        defer { isLoadingPrints = false }
        do {
            let page = try await client.printLog(limit: Self.printHistoryPageSize, offset: printHistory.count)
            // A print finishing between pages shifts every offset by one, which would repeat the
            // first row of this page — drop anything already listed.
            let known = Set(printHistory.map(\.id))
            let fresh = page.items.map(mapPrintRecord).filter { !known.contains($0.id) }
            printHistory = Self.markingVerdictEligibility(printHistory + fresh, eachPrint: serverRatesEachPrint)
            printHistoryTotal = page.total
        } catch {
            // The page loads from the list's last row, whose task is cancelled when it scrolls
            // off screen; it loads again when the row comes back, so that's not worth an alert.
            guard !Self.isCancellation(error) else { return }
            actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The printer's most recent print, if it finished in the last day and can still be given a
    /// verdict — what the printer detail's "How did it come out?" card asks about.
    func recentFinishedPrint(printerID: String) -> PrintRecord? {
        guard let latest = printHistory.first(where: { $0.printerID == printerID }),
              latest.acceptsVerdict,
              let finishedAt = latest.finishedAt,
              Date().timeIntervalSince(finishedAt) < 24 * 60 * 60 else { return nil }
        return latest
    }

    /// Records "how did it come out" (nil clears it). Applied optimistically; a failure puts the
    /// previous answer back.
    func setVerdict(_ verdict: PrintVerdict?, forPrint recordID: String) {
        guard let index = printHistory.firstIndex(where: { $0.id == recordID }),
              printHistory[index].acceptsVerdict,
              let archiveID = printHistory[index].archiveID else { return }
        let previous = printHistory[index].verdict
        guard previous != verdict else { return }
        if isShowingDemoData {
            printHistory[index].verdict = verdict
            return
        }
        guard isLive, let client else {
            actionError = String(localized: "Not connected to your server. Pull to refresh and try again.")
            return
        }
        printHistory[index].verdict = verdict
        Task {
            do {
                try await client.setVerdict(
                    archiveID: archiveID,
                    runID: serverRatesEachPrint ? printHistory.first(where: { $0.id == recordID })?.logID : nil,
                    verdict: verdict?.rawValue
                )
            } catch {
                if let index = printHistory.firstIndex(where: { $0.id == recordID }) {
                    printHistory[index].verdict = previous
                }
                actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Releases a staged job so Bambuddy sends it to the printer once it's free. That dispatch is a
    /// print command, so a printer without Developer LAN mode would refuse it.
    /// `skipFilamentCheck` is Bambuddy's "Print Anyway": the answer to `filamentHold`. Without it,
    /// a job Bambuddy holds over its filament comes back as `filamentHold` for the user to decide.
    func startQueuedPrint(_ itemID: String, skipFilamentCheck: Bool = false) {
        guard let item = queue.first(where: { $0.id == itemID }), item.isStaged else { return }
        if let printerID = item.printerID, refuseWithoutDeveloperMode(printerID) { return }
        if isShowingDemoData, ScreenshotMocks.isActive, !skipFilamentCheck, let hold = ScreenshotMocks.filamentHold {
            filamentHold = FilamentHoldPrompt(itemID: itemID, name: item.name, destination: item.destination, hold: hold)
            return
        }
        performQueueAction(localChange: {
            if let index = self.queue.firstIndex(where: { $0.id == itemID }) { self.queue[index].isStaged = false }
        }, onError: { error in
            guard let hold = error as? QueueStartFilamentHold else { return false }
            // Still staged on the server: put it back so "Print Anyway" passes the guard above
            // without waiting for the reload.
            if let index = self.queue.firstIndex(where: { $0.id == itemID }) { self.queue[index].isStaged = true }
            self.filamentHold = FilamentHoldPrompt(itemID: itemID, name: item.name, destination: item.destination, hold: hold)
            return true
        }) { client in
            try await client.startQueueItem(itemID: item.bambuddyID, skipFilamentCheck: skipFilamentCheck)
        }
    }

    /// A staged job Bambuddy wouldn't start over its filament, waiting for "Print Anyway" or a
    /// cancel (the job stays staged either way until then).
    struct FilamentHoldPrompt: Identifiable, Equatable {
        var itemID: String
        var name: String
        var destination: String
        var hold: QueueStartFilamentHold
        var id: String { itemID }
    }

    var filamentHold: FilamentHoldPrompt?

    /// Takes a pending job out of the queue. Bambuddy keeps no undo — the UI confirms first.
    func removeQueuedPrint(_ itemID: String) {
        guard let item = queue.first(where: { $0.id == itemID }), item.status == .pending else { return }
        performQueueAction(localChange: { self.queue.removeAll { $0.id == itemID } }) { client in
            try await client.removeQueueItem(itemID: item.bambuddyID)
        }
    }

    func canMoveQueuedPrint(_ itemID: String, by offset: Int) -> Bool {
        let pending = queue.filter { $0.status == .pending }
        guard let index = pending.firstIndex(where: { $0.id == itemID }) else { return false }
        return pending.indices.contains(index + offset)
    }

    /// Swaps a pending job with its neighbour in Bambuddy's (global) queue order, then renumbers
    /// every pending job so the positions sent are unique — Bambuddy rejects duplicates.
    func moveQueuedPrint(_ itemID: String, by offset: Int) {
        var pending = queue.filter { $0.status == .pending }
        guard let index = pending.firstIndex(where: { $0.id == itemID }), pending.indices.contains(index + offset) else { return }
        pending.swapAt(index, index + offset)
        for i in pending.indices { pending[i].position = i + 1 }
        let positions = pending.map { (id: $0.bambuddyID, position: $0.position) }
        let printing = queue.filter { $0.status == .printing }
        performQueueAction(localChange: { self.queue = printing + pending }) { client in
            try await client.reorderQueue(positions)
        }
    }

    /// Like `performAction`, but what it refreshes afterwards is the queue, not the printers.
    /// `onError` gets first look at a failure and returns true when it handled it, so no
    /// `actionError` is shown.
    private func performQueueAction(
        localChange: () -> Void,
        onError: @escaping (Error) -> Bool = { _ in false },
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
            } catch {
                if !onError(error) {
                    actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
            await loadPrints()
        }
    }

    func printThumbnail(for record: PrintRecord, maxPixelSize: CGFloat) async -> UIImage? {
        if isShowingDemoData, let data = ScreenshotMocks.coverData(job: record.name) {
            return await ImageDownsampling.image(from: data, maxPixelSize: maxPixelSize)
        }
        return await cachedPrintThumbnail(key: record.id, maxPixelSize: maxPixelSize) { client in
            do {
                return try await client.printLogThumbnailData(entryID: record.logID)
            } catch BambuddyAPIError.http(404, let body) {
                // Bambuddy has no thumbnail for an HTTPS-dispatched print (it never gets the job's
                // 3MF); the relay keeps that print's cover by archive id.
                if let archiveID = record.archiveID, let data = await RelayCoverClient.archiveCoverData(archiveID: archiveID) {
                    return data
                }
                throw BambuddyAPIError.http(404, body)
            }
        }
    }

    func queueThumbnail(for item: QueuedPrint, maxPixelSize: CGFloat) async -> UIImage? {
        if isShowingDemoData, let data = ScreenshotMocks.coverData(job: item.name) {
            return await ImageDownsampling.image(from: data, maxPixelSize: maxPixelSize)
        }
        guard let thumbnail = item.thumbnail else { return nil }
        return await cachedPrintThumbnail(key: item.id, maxPixelSize: maxPixelSize) { client in
            switch thumbnail {
            case .archive(let id): try await client.archiveThumbnailData(archiveID: id)
            case .libraryFile(let id): try await client.libraryFileThumbnailData(fileID: id)
            }
        }
    }

    private func cachedPrintThumbnail(
        key: String,
        maxPixelSize: CGFloat,
        _ fetch: @escaping (BambuddyAPIClient) async throws -> Data
    ) async -> UIImage? {
        let rawKey = "\(key)@\(Int(maxPixelSize))"
        let cacheKey = rawKey as NSString
        if let cached = printThumbnailCache.object(forKey: cacheKey) { return cached }
        if let missedAt = missingPrintThumbnails[key], Date().timeIntervalSince(missedAt) < Self.missingPrintThumbnailRetryInterval { return nil }
        if let existingTask = inFlightPrintThumbnails[rawKey] {
            return await existingTask.value
        }
        guard let client else { return nil }

        let generation = cacheGeneration
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            defer {
                if self.cacheGeneration == generation {
                    self.inFlightPrintThumbnails.removeValue(forKey: rawKey)
                }
            }
            do {
                let data = try await fetch(client)
                guard let image = await ImageDownsampling.image(from: data, maxPixelSize: maxPixelSize) else { return nil }
                if self.cacheGeneration == generation {
                    self.printThumbnailCache.setObject(image, forKey: cacheKey, cost: Self.imageMemoryCost(image))
                }
                return image
            } catch BambuddyAPIError.http(404, _) {
                if self.cacheGeneration == generation {
                    self.missingPrintThumbnails[key] = Date()
                }
                return nil
            } catch {
                return nil
            }
        }
        inFlightPrintThumbnails[rawKey] = task
        return await task.value
    }

    private func mapQueue(_ dtos: [BambuddyQueueItemDTO]) -> [QueuedPrint] {
        dtos.compactMap { dto -> QueuedPrint? in
            let status: QueuedPrint.Status
            switch dto.status {
            case "pending": status = .pending
            case "printing": status = .printing
            default: return nil // finished, failed, skipped and cancelled jobs belong to History
            }
            let printerID = dto.printerId.map { "bb-\($0)" }
            let destination = printerID.flatMap { printer($0)?.name }
                ?? dto.printerName
                ?? dto.targetModel.map { String(localized: "Any \($0)", comment: "Queue job for any printer of a model, e.g. 'Any P1S'") }
                ?? String(localized: "Any printer", comment: "Queue job with no printer chosen")
            let thumbnail: QueuedPrint.Thumbnail? = dto.archiveId.map { .archive($0) } ?? dto.libraryFileId.map { .libraryFile($0) }
            return QueuedPrint(
                id: "q-\(dto.id)",
                bambuddyID: dto.id,
                name: Self.printDisplayName(dto.archiveName ?? dto.libraryFileName) ?? String(localized: "Print job \(dto.id)"),
                printerID: printerID,
                destination: destination,
                status: status,
                position: dto.position,
                isStaged: dto.manualStart,
                scheduledAt: dto.scheduledTime.flatMap(Self.parseBambuddyTimestamp),
                waitingReason: dto.waitingReason,
                estimatedDuration: dto.printTimeSeconds.map(TimeInterval.init),
                filamentGrams: dto.filamentUsedGrams,
                filamentType: dto.filamentType,
                filamentColorHex: dto.filamentColor,
                thumbnail: thumbnail
            )
        }
        .sorted { ($0.status == .printing ? 0 : 1, $0.position) < ($1.status == .printing ? 0 : 1, $1.position) }
    }

    private func mapPrintRecord(_ dto: BambuddyPrintLogEntryDTO) -> PrintRecord {
        let printerID = dto.printerId.map { "bb-\($0)" }
        return PrintRecord(
            id: "log-\(dto.id)",
            logID: dto.id,
            archiveID: dto.archiveId,
            name: Self.printDisplayName(dto.printName) ?? String(localized: "Untitled print"),
            printerID: printerID,
            printerName: printerID.flatMap { printer($0)?.name } ?? dto.printerName,
            outcome: PrintRecord.Outcome(dto.status),
            startedAt: dto.startedAt.flatMap(Self.parseBambuddyTimestamp),
            finishedAt: Self.parseBambuddyTimestamp(dto.completedAt ?? dto.createdAt),
            duration: dto.durationSeconds.map(TimeInterval.init),
            filamentGrams: dto.filamentUsedGrams,
            filamentType: dto.filamentType,
            filamentColorHex: dto.filamentColor,
            cost: dto.cost,
            failureReason: dto.failureReason,
            verdict: dto.userVerdict.flatMap(PrintVerdict.init(rawValue:)),
            acceptsVerdict: false
        )
    }

    /// Sets `acceptsVerdict` on a newest-first list: every completed print with an archive when
    /// Bambuddy keeps a verdict per print (`eachPrint`, 1.3.0+), else only the newest completed run
    /// of each archive (see `PrintRecord.acceptsVerdict`).
    static func markingVerdictEligibility(_ records: [PrintRecord], eachPrint: Bool = false) -> [PrintRecord] {
        var seenArchives: Set<Int> = []
        return records.map { record in
            var record = record
            guard let archiveID = record.archiveID else {
                record.acceptsVerdict = false
                return record
            }
            let isLatestRun = seenArchives.insert(archiveID).inserted
            record.acceptsVerdict = (eachPrint || isLatestRun) && record.outcome == .completed
            return record
        }
    }

    /// File names arrive as uploaded ("Benchy.gcode.3mf"); the slicer extensions are noise in a list.
    nonisolated static func printDisplayName(_ raw: String?) -> String? {
        guard var name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        for suffix in [".gcode.3mf", ".3mf", ".gcode"] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        return name.isEmpty ? nil : name
    }

    // MARK: - Inventory insights

    /// Bambuddy's server-wide low-stock alert level, percent remaining. Its default until the
    /// server says otherwise.
    private(set) var lowStockThreshold: Double = 20
    /// Bambuddy's filament shopping list, newest first.
    private(set) var shoppingList: [ShoppingListItem] = []

    var lowStockSpools: [Spool] { spools.filter(\.isLowStock) }

    /// Entries not yet received — what the shopping-list button counts.
    var openShoppingListCount: Int { shoppingList.filter { $0.status != .received }.count }

    /// The open shopping-list entry for this spool's filament, if there is one.
    func shoppingListItem(for spool: Spool) -> ShoppingListItem? {
        shoppingList.first { $0.status != .received && $0.describes(spool) }
    }

    func loadShoppingList() async {
        guard !isShowingDemoData, let client else { return }
        if let items = try? await client.shoppingList() {
            shoppingList = items.map(Self.mapShoppingListItem)
        }
    }

    /// Adds one spool of this spool's filament to the shopping list, unless it's already there.
    func addToShoppingList(_ spool: Spool) {
        guard shoppingListItem(for: spool) == nil else { return }
        let body = ShoppingListItemCreateBody(
            material: spool.material,
            subtype: spool.subtype?.isEmpty == false ? spool.subtype : nil,
            brand: spool.brand == "Unknown" ? nil : spool.brand,
            colorName: spool.colorName,
            quantitySpools: 1
        )
        let placeholder = ShoppingListItem(
            id: "pending-\(UUID().uuidString)", bambuddyID: -1, material: body.material, subtype: body.subtype,
            brand: body.brand, colorName: body.colorName, quantity: 1, status: .pending, addedAt: Date()
        )
        performShoppingListAction(localChange: { self.shoppingList.insert(placeholder, at: 0) }) { client in
            try await client.addToShoppingList(body)
        }
    }

    func setShoppingListStatus(_ itemID: String, to status: ShoppingListItem.Status) {
        guard let item = shoppingList.first(where: { $0.id == itemID }), item.bambuddyID >= 0, item.status != status else { return }
        performShoppingListAction(localChange: {
            if let index = self.shoppingList.firstIndex(where: { $0.id == itemID }) { self.shoppingList[index].status = status }
        }) { client in
            try await client.setShoppingListStatus(itemID: item.bambuddyID, status: status.rawValue)
        }
    }

    func removeFromShoppingList(_ itemID: String) {
        guard let item = shoppingList.first(where: { $0.id == itemID }), item.bambuddyID >= 0 else { return }
        performShoppingListAction(localChange: { self.shoppingList.removeAll { $0.id == itemID } }) { client in
            try await client.removeFromShoppingList(itemID: item.bambuddyID)
        }
    }

    /// Like `performAction`, refreshing only the shopping list afterwards.
    private func performShoppingListAction(localChange: () -> Void, _ operation: @escaping (BambuddyAPIClient) async throws -> Void) {
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
            } catch {
                actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            await loadShoppingList()
        }
    }

    /// The prints that drew on this spool, newest first. Nil when there's no history to ask for —
    /// demo data, or Spoolman mode, where Bambuddy keeps none.
    func spoolUsage(_ spoolID: String, limit: Int = 25) async -> [SpoolUsageRecord]? {
        guard !isShowingDemoData, inventoryBackend == .builtIn, let client, let bbID = bambuddyID(spoolID) else { return nil }
        guard let dtos = try? await client.spoolUsage(spoolID: bbID, limit: limit) else { return nil }
        return dtos.map { dto in
            SpoolUsageRecord(
                id: dto.id,
                printName: Self.printDisplayName(dto.printName) ?? String(localized: "Untitled print"),
                printerName: dto.printerId.flatMap { printer("bb-\($0)")?.name },
                grams: dto.weightUsed,
                cost: dto.cost,
                date: Self.parseBambuddyTimestamp(dto.createdAt),
                outcome: PrintRecord.Outcome(dto.status)
            )
        }
    }

    private static func mapShoppingListItem(_ dto: BambuddyShoppingListItemDTO) -> ShoppingListItem {
        ShoppingListItem(
            id: "shop-\(dto.id)",
            bambuddyID: dto.id,
            material: dto.material,
            subtype: dto.subtype,
            brand: dto.brand,
            colorName: dto.colorName,
            quantity: dto.quantitySpools,
            note: dto.note,
            status: ShoppingListItem.Status(rawValue: dto.status) ?? .pending,
            addedAt: dto.addedAt.flatMap(parseBambuddyTimestamp)
        )
    }

    // MARK: - Maintenance

    private static func mapMaintenanceTask(_ dto: BambuddyMaintenanceItemDTO) -> MaintenanceTask {
        let isDays = dto.intervalType.lowercased() == "days"
        return MaintenanceTask(
            id: dto.id,
            name: dto.maintenanceTypeName,
            symbol: MaintenanceTask.symbol(forLucideIcon: dto.maintenanceTypeIcon),
            wikiURL: dto.maintenanceTypeWikiUrl.flatMap { URL(string: $0) }.flatMap { ["http", "https"].contains($0.scheme?.lowercased()) ? $0 : nil },
            interval: isDays ? .days(dto.intervalHours) : .printHours(dto.intervalHours),
            elapsed: isDays ? (dto.daysSinceMaintenance ?? 0) : dto.hoursSinceMaintenance,
            remaining: isDays ? (dto.daysUntilDue ?? 0) : dto.hoursUntilDue,
            isDue: dto.isDue,
            isWarning: dto.isWarning,
            lastPerformedAt: dto.lastPerformedAt.flatMap(parseBambuddyTimestamp)
        )
    }

    /// Due first, then warnings, then whatever is closest to due by share of its interval.
    private static func isMoreUrgent(_ a: MaintenanceTask, _ b: MaintenanceTask) -> Bool {
        func rank(_ task: MaintenanceTask) -> Int { task.isDue ? 0 : task.isWarning ? 1 : 2 }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        return a.progress > b.progress
    }

    /// Records a maintenance task as done now. Bambuddy restarts its interval and logs it in the
    /// task's history; the refresh afterwards picks up its new due date.
    func performMaintenance(printerID: String, taskID: Int) {
        guard let printerIndex = printers.firstIndex(where: { $0.id == printerID }) else { return }
        if let bbID = bambuddyID(printerID) {
            maintenanceByPrinterID.removeValue(forKey: bbID)
        }
        performAction(localChange: {
            guard let taskIndex = self.printers[printerIndex].maintenanceTasks.firstIndex(where: { $0.id == taskID }) else { return }
            var task = self.printers[printerIndex].maintenanceTasks[taskIndex]
            switch task.interval {
            case .printHours(let length), .days(let length): task.remaining = length
            }
            task.elapsed = 0
            task.isDue = false
            task.isWarning = false
            task.lastPerformedAt = Date()
            self.printers[printerIndex].maintenanceTasks[taskIndex] = task
            let tasks = self.printers[printerIndex].maintenanceTasks
            self.printers[printerIndex].maintenanceTasks = tasks.sorted(by: Self.isMoreUrgent)
            self.printers[printerIndex].maintenanceOK = !tasks.contains { $0.isDue || $0.isWarning }
        }) { client in
            try await client.performMaintenance(itemID: taskID)
        }
    }
}

/// Debug builds launched with `-NCScreenshotMode` (the fastlane screenshot workflow, see
/// fastlane/README.md) hide the demo-data banner. Always off in release builds.
nonisolated enum ScreenshotMode {
    #if DEBUG
    static let isActive = ProcessInfo.processInfo.arguments.contains("-NCScreenshotMode")
    #else
    static let isActive = false
    #endif
}
