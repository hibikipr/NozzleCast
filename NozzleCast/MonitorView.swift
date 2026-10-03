import SwiftUI

struct MonitorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var showNotifications = false
    @State private var unreadCount = 0
    @State private var path: [String] = []
    @Binding var selectedTab: RootTab

    private var printingCount: Int { store.printers.filter { $0.state == .printing }.count }
    private var attentionCount: Int { store.printers.filter(\.needsAttention).count }

    /// Grouped like Bambuddy's printer page: anything needing attention first, then what's
    /// printing, then what just finished, then idle and offline — each group in server order.
    private var sortedPrinters: [Printer] {
        func rank(_ printer: Printer) -> Int {
            if printer.needsAttention { return 0 }
            switch printer.state {
            case .printing, .paused: return 1
            case .finished, .failed: return 2
            case .idle: return 3
            case .offline: return 4
            }
        }
        return store.printers.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    /// The printer's most recent print from the loaded history, for its idle card.
    private func lastPrint(for printerID: String) -> LastPrintSummary? {
        store.printHistory.first { $0.printerID == printerID }.map {
            LastPrintSummary(name: $0.name, outcome: $0.outcome, verdict: $0.verdict, finishedAt: $0.finishedAt)
        }
    }

    private var isConnecting: Bool { store.isLoadingPrinters }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("NozzleCast")
                                .ncFont(size: 34, weight: .bold, relativeTo: .largeTitle)
                            Group {
                                if isConnecting {
                                    Text("Connecting to server…")
                                } else {
                                    // Automatic grammar agreement: "1 printer", "2 printers".
                                    if attentionCount == 1 {
                                        Text("\(printingCount) printing · 1 needs attention", comment: "Monitor header when one printer needs attention")
                                    } else if attentionCount > 1 {
                                        Text("\(printingCount) printing · \(attentionCount) need attention", comment: "Monitor header when several printers need attention")
                                    } else {
                                        Text("\(printingCount) printing · ^[\(store.printers.count) printer](inflect: true)")
                                    }
                                }
                            }
                            .ncFont(size: 15, relativeTo: .subheadline)
                            .foregroundStyle(NCColor.textSecondary)
                        }
                        Spacer()
                        Button {
                            showNotifications = true
                        } label: {
                            Image(systemName: unreadCount > 0 ? "bell.badge.fill" : "bell")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(unreadCount > 0 ? NCColor.accentLight : .white)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(NCColor.cardFill))
                        }
                        .padding(.top, 10)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                    if store.isShowingDemoData {
                        DemoDataBanner(connectionStatus: store.connectionStatus) { selectedTab = .settings }
                            .padding(.horizontal, 16)
                    } else if let message = store.serverUnreachableMessage {
                        ServerUnreachableBanner(message: message) { selectedTab = .settings }
                            .padding(.horizontal, 16)
                    }

                    if isConnecting {
                        VStack(spacing: 14) {
                            ProgressView().tint(NCColor.accentLight)
                            Text("Loading your printers…")
                                .ncFont(size: 13, relativeTo: .footnote)
                                .foregroundStyle(NCColor.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                    } else {
                        ForEach(sortedPrinters) { printer in
                            NavigationLink(value: printer.id) {
                                PrinterCard(
                                    id: printer.id,
                                    name: printer.name,
                                    state: printer.state,
                                    jobFileName: printer.jobFileName,
                                    progress: printer.progress,
                                    etaDescription: printer.etaDescription,
                                    estimatedFinish: printer.estimatedFinish,
                                    currentLayer: printer.currentLayer,
                                    totalLayers: printer.totalLayers,
                                    stageDetail: printer.stageDetail,
                                    alertCount: printer.hmsErrors.count,
                                    alertLevel: printer.alertLevel,
                                    nozzleTemp: printer.nozzle.current,
                                    bedTemp: printer.bed.current,
                                    awaitingPlateClear: printer.awaitingPlateClear,
                                    lastPrint: lastPrint(for: printer.id),
                                    allTrays: printer.allTrays,
                                    imageAssetName: printer.imageAssetName
                                )
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 16)
                        }
                    }
                }
                .padding(.bottom, 100)
            }
            .background(NCColor.canvasBackground.ignoresSafeArea())
            .navigationBarHidden(true)
            .refreshable { await store.testConnectionAndRefresh() }
            .navigationDestination(for: String.self) { id in
                PrinterDetailView(printerID: id)
            }
            .sheet(isPresented: $showNotifications, onDismiss: refreshUnreadCount) {
                NavigationStack {
                    NotificationsView()
                }
            }
            .onAppear { refreshUnreadCount() }
            // Idle cards recap each printer's last print from the print history; a print that just
            // finished isn't in it until it's reloaded.
            .task(id: store.printers.map(\.state)) { await store.loadPrints() }
            // Without Firebase, alerts land in the history during a refresh (BambuddyAlertFeed),
            // not through the notification extension — re-read the badge after each one.
            .onChange(of: store.lastSuccessfulRefreshAt) { refreshUnreadCount() }
            .onChange(of: store.pendingDeepLinkPrinterID) { _, id in
                guard let id else { return }
                path = [id]
                store.pendingDeepLinkPrinterID = nil
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { break }
                    if case .connected = store.connectionStatus, !store.isRefreshing {
                        NSLog("NCDEBUG poll: foreground refresh tick")
                        await store.refresh()
                    } else if case .failed = store.connectionStatus {
                        // 421 / transient network errors drop connectionStatus to .failed;
                        // rather than waiting for the next foreground event, reconnect here.
                        NSLog("NCDEBUG poll: reconnect attempt after failed state")
                        await store.testConnectionAndRefresh()
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: NSLog("NCDEBUG scenePhase -> active (connectionStatus=%@)", String(describing: store.connectionStatus))
                case .inactive: NSLog("NCDEBUG scenePhase -> inactive")
                case .background:
                    NSLog("NCDEBUG scenePhase -> background")
                    BambuddyAlertFeed.scheduleBackgroundCheck()
                @unknown default: break
                }
                guard phase == .active else { return }
                refreshUnreadCount()
                // ActivityKit only allows starting a *new* Live Activity while the app is
                // foreground (Notification Service Extension attempts to do it while
                // backgrounded/locked always throw `.visibility` — see
                // NotificationService.updateLiveActivity). This is what actually catches up a
                // print that started while the app was backgrounded: a cold launch already
                // triggers AppStore.init()'s refresh, but resuming an app the system kept alive
                // in memory doesn't re-run init, so without this a still-live process would sit
                // there showing no Live Activity until manually pulled-to-refresh.
                if store.isLive {
                    Task { await store.refresh() }
                } else if case .failed = store.connectionStatus {
                    // A transient launch failure (e.g. network not yet routed) leaves
                    // connectionStatus as .failed, which makes isLive false and blocks
                    // the refresh above — so the app stays stuck on mock data forever
                    // without a pull-to-refresh. Retry the full connection here instead.
                    Task { await store.testConnectionAndRefresh() }
                }
            }
        }
    }

    private func refreshUnreadCount() {
        unreadCount = PushSharedStore.unreadCount()
    }
}

/// The last finished print on a printer, as the idle card's one-line recap.
struct LastPrintSummary: Equatable {
    var name: String
    var outcome: PrintRecord.Outcome
    var verdict: PrintVerdict?
    var finishedAt: Date?
}

/// One printer on the Monitor tab, laid out like Bambuddy's printer card: the printer's state on
/// its own line and any HMS alert as a separate pill, never one in place of the other. Every card
/// has the same minimum height whatever the state, so the list doesn't jump as prints start and
/// finish.
///
/// Narrow, per-field inputs rather than the whole `Printer` struct, so the card doesn't re-render
/// when a field it doesn't show (fans, Wi-Fi, maintenance, …) changes on a refresh.
struct PrinterCard: View {
    var id: String
    var name: String
    var state: PrinterState
    var jobFileName: String?
    var progress: Double?
    var etaDescription: String?
    var estimatedFinish: Date?
    var currentLayer: Int?
    var totalLayers: Int?
    /// Extra detail beyond `state.label` — e.g. "Heatbed preheating", or "Purifying the chamber
    /// air" after progress hits 100%. Nil most of the time.
    var stageDetail: String?
    var alertCount: Int
    var alertLevel: HMSError.Level?
    var nozzleTemp: Int?
    var bedTemp: Int?
    var awaitingPlateClear: Bool
    var lastPrint: LastPrintSummary?
    var allTrays: [AMSTray]
    var imageAssetName: String?
    @Environment(AppStore.self) private var store
    @State private var isCameraLive = false

    private static let thumbnailSize: CGFloat = 80

    private var hasJob: Bool { state == .printing || state == .paused }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            thumbnail

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name)
                        .ncFont(size: 16, weight: .semibold, relativeTo: .headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if hasJob, let nozzleTemp, let bedTemp {
                        temperatures(nozzle: nozzleTemp, bed: bedTemp)
                    }
                    if alertCount > 0, let alertLevel {
                        InfoPill(icon: HMSError.Level.pillSymbol, text: "\(alertCount)", tint: alertLevel.color)
                            .accessibilityLabel(Text("^[\(alertCount) alert](inflect: true)", comment: "Accessibility label for a printer card's alert pill"))
                    }
                }

                statusLine

                if hasJob {
                    if let job = jobFileName {
                        Text(job)
                            .ncFont(size: 12.5, relativeTo: .caption)
                            .foregroundStyle(NCColor.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    ProgressBar(progress: progress ?? 0, tint: state == .paused ? NCColor.statusWarning : NCColor.statusPrinting)
                        .padding(.top, 2)
                    progressFooter
                } else if state != .offline {
                    idleDetail
                }

                if !allTrays.isEmpty {
                    FlowLayout(spacing: 6, rowSpacing: 6) {
                        ForEach(allTrays) { tray in
                            let spool = store.spool(tray.spoolID)
                            Group {
                                if let spool { spool.swatch.clipShape(Circle()) }
                                else { Circle().fill(Color.white.opacity(0.08)) }
                            }
                            .frame(width: 13, height: 13)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NCColor.textTertiary)
                .frame(height: Self.thumbnailSize)
        }
        .frame(minHeight: Self.thumbnailSize, alignment: .top)
        .padding(14)
        .glassCard()
    }

    /// "● Printing · Heatbed preheating" — the phase in its own color.
    private var statusLine: some View {
        HStack(spacing: 6) {
            StatusDot(state: state)
            Text(stageDetail.map { "\(state.label) · \($0)" } ?? state.label)
                .ncFont(size: 13, weight: .medium, relativeTo: .footnote)
                .foregroundStyle(state == .idle || state == .offline ? NCColor.textSecondary : state.color)
                .lineLimit(1)
        }
    }

    /// "62% · 140/226" on the left, "48m · 10:42" on the right — terse, as the card is narrow;
    /// the printer screen's job card spells it out. The times never truncate; the layer count
    /// gives way first.
    private var progressFooter: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(progress ?? 0, format: .percent.precision(.fractionLength(0)))
                if let currentLayer, let totalLayers, totalLayers > 0 {
                    Text("· \(currentLayer)/\(totalLayers)", comment: "Print progress in layers on a printer card, e.g. '· 140/226'")
                        .accessibilityLabel(Text("layer \(currentLayer) of \(totalLayers)", comment: "Accessibility label for the layer count on a printer card"))
                }
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            if let etaDescription {
                HStack(spacing: 4) {
                    Text(etaDescription)
                        .accessibilityLabel(Text("\(etaDescription) left", comment: "Remaining print time, e.g. '12m left'"))
                    if let estimatedFinish {
                        Text("· \(estimatedFinish.formatted(date: .omitted, time: .shortened))", comment: "Clock time the print should finish")
                    }
                }
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
            }
        }
        .ncFont(size: 12, weight: .medium, relativeTo: .caption)
        .foregroundStyle(NCColor.textTertiary)
    }

    /// What's worth knowing about a printer that isn't printing: whether the plate is clear for
    /// the next job, and how the last print came out.
    @ViewBuilder
    private var idleDetail: some View {
        Label(
            awaitingPlateClear
                ? String(localized: "Plate not clear", comment: "Printer card: parts still on the build plate")
                : String(localized: "Plate clear", comment: "Printer card: build plate is empty"),
            systemImage: awaitingPlateClear ? "square.dashed" : "checkmark.square"
        )
        .ncFont(size: 12.5, relativeTo: .caption)
        .foregroundStyle(awaitingPlateClear ? NCColor.statusWarning : NCColor.textSecondary)
        .labelStyle(.titleAndIcon)

        if let lastPrint {
            // Only the name gives way to a narrow card; the outcome and time always show.
            HStack(spacing: 4) {
                Text("Last: \(lastPrint.name)", comment: "Printer card: the printer's most recent print")
                    .lineLimit(1)
                    .truncationMode(.tail)
                let suffix = lastPrintSuffix(lastPrint)
                if !suffix.isEmpty {
                    Text("· \(suffix)")
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .ncFont(size: 12, relativeTo: .caption)
            .foregroundStyle(NCColor.textTertiary)
        }
    }

    /// "Good · 19 hours ago", the part of the last-print line after its name.
    private func lastPrintSuffix(_ last: LastPrintSummary) -> String {
        var parts: [String] = []
        switch (last.outcome, last.verdict) {
        case (.failed, _): parts.append(String(localized: "Failed", comment: "Print history status"))
        case (.cancelled, _): parts.append(String(localized: "Cancelled", comment: "Print history status"))
        case (_, .good?): parts.append(String(localized: "Good", comment: "Print verdict"))
        case (_, .reject?): parts.append(String(localized: "Reject", comment: "Print verdict"))
        default: break
        }
        if let finishedAt = last.finishedAt {
            parts.append(finishedAt.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    private func temperatures(nozzle: Int, bed: Int) -> some View {
        HStack(spacing: 6) {
            Label("\(nozzle)°", systemImage: "flame")
            Label("\(bed)°", systemImage: "square.3.layers.3d.bottom.filled")
        }
        .labelStyle(CompactIconLabelStyle())
        .ncFont(size: 11.5, weight: .medium, relativeTo: .caption2)
        .foregroundStyle(NCColor.textTertiary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Nozzle \(nozzle) degrees, bed \(bed) degrees", comment: "Accessibility label for a printer card's temperatures"))
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(NCColor.printerWell)
            if state == .printing {
                LiveCameraView(printerID: id, pollInterval: 5, maxPixelSize: Self.thumbnailSize * 3, coverFallbackJobIdentity: jobFileName ?? id, isShowingLiveFrame: $isCameraLive)
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PrinterThumbnailImage(assetName: imageAssetName)
                    .padding(10)
            }
        }
        .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(NCColor.printerWellBorder, lineWidth: 1)
        )
        .overlay(alignment: .topLeading) {
            if isCameraLive {
                LiveBadge().padding(5)
            }
        }
    }
}

private struct CompactIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon.font(.system(size: 10, weight: .semibold))
            configuration.title
        }
    }
}

#Preview {
    MonitorView(selectedTab: .constant(.monitor))
        .environment(AppStore(config: BambuddyConfig()))
        .preferredColorScheme(.dark)
}
