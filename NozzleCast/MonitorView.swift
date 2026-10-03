import SwiftUI

struct MonitorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var showNotifications = false
    @State private var unreadCount = 0
    @State private var path: [String] = []
    @Binding var selectedTab: RootTab

    private var printingCount: Int { store.printers.filter { $0.state == .printing }.count }

    private var isConnecting: Bool { store.isLoadingPrinters }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("NozzleCast")
                                .ncFont(size: 34, weight: .bold, relativeTo: .largeTitle)
                            Group {
                                if isConnecting {
                                    Text("Connecting to server…")
                                } else {
                                    // Automatic grammar agreement: "1 printer", "2 printers".
                                    Text("\(printingCount) printing · ^[\(store.printers.count) printer](inflect: true)")
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
                        ForEach(store.printers) { printer in
                            NavigationLink(value: printer.id) {
                                PrinterCard(
                                    id: printer.id,
                                    name: printer.name,
                                    state: printer.state,
                                    jobFileName: printer.jobFileName,
                                    progress: printer.progress,
                                    etaDescription: printer.etaDescription,
                                    stageDetail: printer.stageDetail,
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

/// Narrow, per-field inputs rather than the whole `Printer` struct — this row only renders
/// these 8 fields, so it shouldn't re-render when an unrelated field (temps, HMS errors, wifi,
/// maintenance, etc.) changes on this same printer during a refresh.
struct PrinterCard: View {
    var id: String
    var name: String
    var state: PrinterState
    var jobFileName: String?
    var progress: Double?
    var etaDescription: String?
    /// Extra detail beyond `state.label` — e.g. "Purifying the chamber air" during a print's
    /// post-completion chamber-purification cycle. Nil most of the time.
    var stageDetail: String?
    var allTrays: [AMSTray]
    var imageAssetName: String?
    @Environment(AppStore.self) private var store
    @State private var isCameraLive = false

    var body: some View {
        HStack(spacing: 12) {
            thumbnail

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(name)
                        .ncFont(size: 16, weight: .semibold, relativeTo: .headline)
                        .foregroundStyle(.white)
                    Spacer()
                    HStack(spacing: 5) {
                        StatusDot(state: state)
                        Text(state.label)
                            .ncFont(size: 13, weight: .medium, relativeTo: .footnote)
                            .foregroundStyle(NCColor.textSecondary)
                    }
                }

                if state == .printing || state == .paused, let job = jobFileName {
                    Text(job)
                        .ncFont(size: 12.5, relativeTo: .caption)
                        .foregroundStyle(NCColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ProgressBar(progress: progress ?? 0)
                    HStack {
                        Text(progress ?? 0, format: .percent.precision(.fractionLength(0)))
                        Text("·")
                        Text("\(etaDescription ?? "--") left", comment: "Remaining print time, e.g. '12m left'")
                    }
                    .ncFont(size: 12, weight: .medium, relativeTo: .caption)
                    .foregroundStyle(NCColor.textTertiary)
                    if let stageDetail {
                        Text(stageDetail)
                            .ncFont(size: 11.5, relativeTo: .caption2)
                            .foregroundStyle(NCColor.textTertiary)
                            .lineLimit(1)
                    }
                    if !allTrays.isEmpty {
                        FlowLayout(spacing: 6, rowSpacing: 6) {
                            ForEach(allTrays) { tray in
                                let spool = store.spool(tray.spoolID)
                                Group {
                                    if let spool { spool.swatch.clipShape(Circle()) }
                                    else { Circle().fill(Color.white.opacity(0.08)) }
                                }
                                .frame(width: 11, height: 11)
                            }
                        }
                    }
                } else if !allTrays.isEmpty {
                    FlowLayout(spacing: 7, rowSpacing: 7) {
                        ForEach(allTrays) { tray in
                            let spool = store.spool(tray.spoolID)
                            Group {
                                if let spool { spool.swatch.clipShape(Circle()) }
                                else { Circle().fill(Color.white.opacity(0.08)) }
                            }
                            .frame(width: 15, height: 15)
                        }
                    }
                }
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NCColor.textTertiary)
        }
        .padding(12)
        .glassCard()
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(NCColor.printerWell)
            if state == .printing {
                LiveCameraView(printerID: id, pollInterval: 5, maxPixelSize: 180, coverFallbackJobIdentity: jobFileName ?? id, isShowingLiveFrame: $isCameraLive)
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PrinterThumbnailImage(assetName: imageAssetName)
                    .padding(8)
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(NCColor.printerWellBorder, lineWidth: 1)
        )
        .overlay(alignment: .topLeading) {
            if isCameraLive {
                LiveBadge().padding(4)
            }
        }
    }
}

#Preview {
    MonitorView(selectedTab: .constant(.monitor))
        .environment(AppStore(config: BambuddyConfig()))
        .preferredColorScheme(.dark)
}
