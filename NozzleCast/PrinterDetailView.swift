import SwiftUI

struct PrinterDetailView: View {
    var printerID: String
    /// `false` when shown as a `NavigationSplitView` detail column (regular-width iPad/open or
    /// partially-open Duo) — there the tab bar and printer list stay on screen alongside this
    /// view, so hiding the tab bar here would strand the user with no way to reach the other
    /// tabs. `true` (the default) matches every other call site, where this view is a genuine
    /// full-screen push.
    var hidesTabBar: Bool = true
    /// Overrides the video header's back button when this view isn't reached by a real
    /// navigation push — e.g. `MonitorView`'s `NavigationSplitView` detail column sets
    /// `selectedPrinterID` directly rather than pushing, so `@Environment(\.dismiss)` has
    /// nothing to dismiss and silently does nothing. `nil` (the default) matches every other
    /// call site, where this view is a genuine pushed destination and the default `dismiss()`
    /// behavior is correct.
    var onBack: (() -> Void)? = nil
    /// SF Symbol shown by the button that triggers `onBack`. Callers that repurpose `onBack` for
    /// something other than a literal "go back" — e.g. `MonitorView` toggles the list column's
    /// visibility instead of navigating anywhere — should pass an icon that matches what
    /// actually happens (`"sidebar.left"`) rather than the default back chevron.
    var backIcon: String = "chevron.left"
    @Environment(AppStore.self) private var store
    @State private var assignTray: AMSTray?
    @State private var showWarnings = false
    @State private var showCoverFullscreen = false
    @State private var isCameraLive = false
    @State private var showAIDetection = false
    @State private var showLiveStream = false
    @State private var showMaintenance = false

    private var printer: Printer? { store.printer(printerID) }

    var body: some View {
        if let printer {
            PrinterDetailContent(
                printer: printer,
                hidesTabBar: hidesTabBar,
                onBack: onBack,
                backIcon: backIcon,
                isCameraLive: $isCameraLive,
                assignTray: $assignTray,
                showWarnings: $showWarnings,
                showAIDetection: $showAIDetection,
                showMaintenance: $showMaintenance,
                showCoverFullscreen: $showCoverFullscreen,
                showLiveStream: $showLiveStream
            )
            // Print history feeds the "How did it come out?" card, and a print that just finished
            // isn't in the history the app has yet. Attached here rather than to the card, which
            // renders nothing until that history exists — SwiftUI never runs a task on an empty
            // view, so the card could never load what it needs to appear.
            .task(id: printer.state) { await store.loadPrints() }
            .fullScreenCover(isPresented: $showLiveStream) {
                LiveCameraStreamView(printerID: printer.id, printerName: printer.name)
            }
            .sheet(item: $assignTray) { tray in
                AMSAssignSheet(printerID: printerID, amsIndex: tray.amsIndex, trayIndex: tray.trayIndex)
            }
            .sheet(isPresented: $showWarnings) {
                HMSWarningsSheet(printerName: printer.name, errors: printer.hmsErrors)
            }
            .fullScreenCover(isPresented: $showCoverFullscreen) {
                CoverImageViewer(printerID: printer.id, jobIdentity: printer.jobFileName ?? printer.id)
            }
            .sheet(isPresented: $showMaintenance) {
                MaintenanceSheet(printerID: printer.id)
            }
            .sheet(isPresented: $showAIDetection) {
                AIDetectionSheet(printerName: printer.name, isMonitoring: printer.aiMonitoringActive, lastError: printer.aiLastError)
            }
        } else {
            ContentUnavailableView(String(localized: "Printer not found"), systemImage: "printer.fill")
        }
    }
}

/// The whole screen still re-evaluates whenever the store's `printers` array changes at all
/// (since `printer` above is looked up by id from the whole collection), but each section below
/// is its own `View` type with narrow inputs, so a change to a *different* printer — or to a
/// field of *this* printer that a given section doesn't render — only reconstructs that
/// section's input values; it doesn't re-run the section's own body.
struct PrinterDetailContent: View {
    var printer: Printer
    var hidesTabBar: Bool
    var onBack: (() -> Void)?
    var backIcon: String = "chevron.left"
    @Binding var isCameraLive: Bool
    @Binding var assignTray: AMSTray?
    @Binding var showWarnings: Bool
    @Binding var showAIDetection: Bool
    @Binding var showMaintenance: Bool
    @Binding var showCoverFullscreen: Bool
    @Binding var showLiveStream: Bool
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            // `ArrangementView`'s `.split` style engages based on aspect ratio alone (it splits
            // vertically whenever the available space is taller than wide) — not on whether a
            // hinge is actually present. Almost every phone screen in portrait is taller than
            // wide, so gating on that alone would pin the video into its own fixed top pane on
            // every pose, not just a genuinely half-open Duo laid flat. Checking for an active
            // `.division` reserved region — the region the hinge itself carves out — is what
            // actually distinguishes "hinge splitting the screen right now" from "just a tall
            // window", and is the only case where we want the video pinned above a separately
            // scrolling controls pane instead of everything scrolling together as one column.
            if #available(iOS 27.1, *) {
                GeometryReader { proxy in
                    if proxy.reservedRegions(kind: .division).isEmpty {
                        plainScrollingContent
                    } else {
                        ArrangementView {
                            PrinterVideoHeader(printerID: printer.id, state: printer.state, jobFileName: printer.jobFileName, isCameraLive: $isCameraLive, showLiveStream: $showLiveStream, onBack: onBack, backIcon: backIcon, fillsAvailableHeight: true)
                        } secondary: {
                            ScrollView {
                                controlsAndInfo
                            }
                        }
                        .arrangementViewStyle(.split.axes(.vertical))
                    }
                }
            } else {
                plainScrollingContent
            }
        }
        .background(NCColor.canvasBackground.ignoresSafeArea())
        .navigationBarHidden(true)
        .toolbar(hidesTabBar ? .hidden : .visible, for: .tabBar)
    }

    private var plainScrollingContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PrinterVideoHeader(printerID: printer.id, state: printer.state, jobFileName: printer.jobFileName, isCameraLive: $isCameraLive, showLiveStream: $showLiveStream, onBack: onBack, backIcon: backIcon)
                controlsAndInfo
            }
        }
    }

    @ViewBuilder
    private var controlsAndInfo: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(printer.name)
                            .ncFont(size: 24, weight: .bold, relativeTo: .title)
                        Spacer(minLength: 8)
                        // Feedback for the "Refresh Status" menu item, which otherwise changed
                        // nothing visible when the data was already current. Trailing, so it
                        // doesn't shift anything when it comes and goes.
                        if store.isUserRefreshing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small).tint(NCColor.accentLight)
                                Text("Refreshing…", comment: "Shown next to the printer name while a user-requested refresh runs")
                                    .ncFont(size: 12, relativeTo: .caption)
                                    .foregroundStyle(NCColor.textTertiary)
                            }
                        }
                    }
                    PrinterStatusLine(model: printer.model, state: printer.state, stageDetail: printer.stageDetail)
                }
                .padding(.horizontal, 16)

                PrinterInfoPillRow(
                    model: printer.model,
                    wifiSignalDBm: printer.wifiSignalDBm,
                    hmsErrorCount: printer.hmsErrors.count,
                    hmsWorstLevel: printer.alertLevel,
                    aiDetectionEnabled: printer.aiDetectionEnabled,
                    aiMonitoringActive: printer.aiMonitoringActive,
                    firmwareVersion: printer.firmwareVersion,
                    totalPrintHours: printer.totalPrintHours,
                    maintenanceOK: printer.maintenanceOK,
                    doorOpen: printer.doorOpen,
                    showWarnings: $showWarnings,
                    showAIDetection: $showAIDetection,
                    showMaintenance: $showMaintenance
                )
                .padding(.horizontal, 16)

                // Ordered by what matters in each state: while printing, the job, its controls
                // and the temperatures; otherwise the last print and the AMS — what's loaded for
                // the next job — ahead of temperatures that are just sitting at room temperature.
                if isRunningJob {
                    if let job = printer.jobFileName {
                        PrinterJobCard(
                            printerID: printer.id,
                            job: job,
                            isPaused: printer.state == .paused,
                            progress: printer.progress,
                            etaDescription: printer.etaDescription,
                            estimatedFinish: printer.estimatedFinish,
                            currentLayer: printer.currentLayer,
                            totalLayers: printer.totalLayers,
                            showCoverFullscreen: $showCoverFullscreen
                        )
                        .padding(.horizontal, 16)
                    }
                    controls
                    temperatures
                    ams
                    fans
                } else {
                    if printer.state != .offline {
                        PrinterLastPrintCard(printerID: printer.id, awaitingPlateClear: printer.awaitingPlateClear, showCoverFullscreen: $showCoverFullscreen)
                            .padding(.horizontal, 16)
                    }
                    controls
                    ams
                    temperatures
                    fans
                }

                if !printer.nozzleRack.isEmpty {
                    PrinterNozzleRackSection(nozzleRack: printer.nozzleRack)
                        .padding(.horizontal, 16)
                }

                if let smartPlug = printer.smartPlug {
                    PrinterPowerSection(printerID: printer.id, smartPlug: smartPlug)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 32)
                } else {
                    Color.clear.frame(height: 12)
                }
            }
        }

    private var isRunningJob: Bool { printer.state == .printing || printer.state == .paused }

    private var controls: some View {
        PrinterControlsRow(printerID: printer.id, state: printer.state, lightOn: printer.lightOn, lacksDeveloperMode: printer.lacksDeveloperMode, showLiveStream: $showLiveStream)
            .padding(.horizontal, 16)
    }

    private var temperatures: some View {
        PrinterTemperaturesSection(nozzle: printer.nozzle, rightNozzle: printer.rightNozzle, bed: printer.bed, chamber: printer.chamber)
            .padding(.horizontal, 16)
    }

    /// Hidden while nothing is printing and every fan is off: three 0% readings say nothing.
    @ViewBuilder
    private var fans: some View {
        let speeds = printer.fanSpeeds
        let anySpinning = [speeds.partCooling, speeds.auxiliary, speeds.chamber].contains { ($0 ?? 0) > 0 }
        if isRunningJob || anySpinning {
            PrinterFansSection(fanSpeeds: speeds)
                .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var ams: some View {
        if !printer.amsUnits.isEmpty {
            PrinterAMSSection(printerID: printer.id, amsUnits: printer.amsUnits, isDualNozzle: printer.isDualNozzle, activeTrayID: printer.activeTrayID, assignTray: $assignTray)
                .padding(.horizontal, 16)
        }
        if !printer.externalTrays.isEmpty {
            PrinterExternalSection(externalTrays: printer.externalTrays, activeTrayID: printer.activeTrayID)
                .padding(.horizontal, 16)
        }
    }
}

/// "H2C · ● Printing · Heatbed preheating" — the model, then the state in its own color, as on
/// the Monitor card.
struct PrinterStatusLine: View {
    var model: String
    var state: PrinterState
    var stageDetail: String?

    var body: some View {
        HStack(spacing: 6) {
            Text("\(model) ·", comment: "Printer model, before its status")
                .foregroundStyle(NCColor.textSecondary)
            StatusDot(state: state)
            Text(stageDetail.map { "\(state.label) · \($0)" } ?? state.label)
                .foregroundStyle(state == .idle || state == .offline ? NCColor.textSecondary : state.color)
                .lineLimit(1)
        }
        .ncFont(size: 15, relativeTo: .subheadline)
    }
}

/// Shared menu content for the header ellipsis button and the controls row's "More" menu.
/// Only needs the printer's id, not the whole `Printer`.
struct PrinterMoreMenuItems: View {
    var printerID: String
    @Binding var showLiveStream: Bool
    @Environment(AppStore.self) private var store

    var body: some View {
        Button {
            Task { await store.refreshFromUser() }
        } label: {
            Label("Refresh Status", systemImage: "arrow.clockwise")
        }

        if store.isLive {
            Button {
                store.homeAxes(printerID)
            } label: {
                Label("Home Axes", systemImage: "house")
            }
            .disabled(store.printer(printerID)?.lacksDeveloperMode == true)

            // In-app, rather than Bambuddy's /camera/<id> page in Safari: that page only gets a
            // stream token in a browser logged in to Bambuddy, so opened from here it loaded with
            // no video at all.
            Button {
                showLiveStream = true
            } label: {
                Label("Live Camera", systemImage: "video")
            }
        }
    }
}

struct PrinterVideoHeader: View {
    var printerID: String
    var state: PrinterState
    var jobFileName: String?
    @Binding var isCameraLive: Bool
    @Binding var showLiveStream: Bool
    /// Overrides the back button when this view isn't a real pushed destination (see
    /// `PrinterDetailView.onBack`). `nil` (the default) uses `dismiss()` as before.
    var onBack: (() -> Void)? = nil
    /// SF Symbol for the back button; see `PrinterDetailView.backIcon`.
    var backIcon: String = "chevron.left"
    /// `true` when used as an `ArrangementView` primary pane (a partially-open iPhone Duo laid
    /// flat, book/tabletop posture) — there the pane's height comes from the arrangement itself
    /// rather than a fixed card height, so the video should fill whatever space it's given
    /// instead of the fixed 250pt height used everywhere else this view appears.
    var fillsAvailableHeight: Bool = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "#2a2a2a"), Color(hex: "#141414")], startPoint: .top, endPoint: .bottom)
            if state == .offline {
                Image(systemName: "camera.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.3))
            } else {
                LiveCameraView(printerID: printerID, pollInterval: 3, showsErrorDetail: true, coverFallbackJobIdentity: jobFileName ?? printerID, isShowingLiveFrame: $isCameraLive, isPaused: showLiveStream)
                    .font(.system(size: 44))
            }
        }
        .frame(height: fillsAvailableHeight ? nil : 250)
        .frame(maxHeight: fillsAvailableHeight ? .infinity : nil)
        .overlay(alignment: .topLeading) {
            HStack {
                GlassIconButton(systemName: backIcon) { onBack?() ?? dismiss() }
                Spacer()
                Menu {
                    PrinterMoreMenuItems(printerID: printerID, showLiveStream: $showLiveStream)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(.black.opacity(0.45)))
                        .background(Circle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark))
                }
            }
            .padding(16)
        }
        .overlay(alignment: .topLeading) {
            Group {
                if state == .offline {
                    offlinePill
                } else if isCameraLive {
                    LiveBadge().scaleEffect(1.3)
                }
            }
            .padding(.top, 60)
            .padding(.leading, 16)
        }
        .clipped()
    }

    private var offlinePill: some View {
        Text("OFFLINE")
            .ncFont(size: 9, weight: .bold, relativeTo: .caption2)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.55)))
    }
}

struct PrinterInfoPillRow: View {
    var model: String
    var wifiSignalDBm: Int?
    var hmsErrorCount: Int
    /// The most severe active alert, which colors the alert pill — red for a fault that stopped
    /// the print, orange for one that paused it, blue when only notifications are active.
    var hmsWorstLevel: HMSError.Level?
    var aiDetectionEnabled: Bool
    var aiMonitoringActive: Bool
    var firmwareVersion: String?
    var totalPrintHours: Double?
    var maintenanceOK: Bool?
    var doorOpen: Bool
    @Binding var showWarnings: Bool
    @Binding var showAIDetection: Bool
    @Binding var showMaintenance: Bool

    /// Bambuddy's `door_open` field defaults to false for every printer model rather than
    /// being nil when a model has no door to report on, so it can't tell us on its own whether
    /// a "closed" reading is meaningful or just the default. The H2 series (H2C/H2D/H2S) is the
    /// enclosed line with an actual front-door sensor Bambuddy surfaces this for.
    private var hasDoorSensor: Bool { model.uppercased().contains("H2") }

    var body: some View {
        FlowLayout(spacing: 6, rowSpacing: 6) {
            if let dbm = wifiSignalDBm {
                InfoPill(icon: "wifi", text: "\(dbm)dBm")
            }
            if hmsErrorCount > 0 {
                Button {
                    showWarnings = true
                } label: {
                    InfoPill(icon: HMSError.Level.pillSymbol, text: "\(hmsErrorCount)", tint: (hmsWorstLevel ?? .warning).color)
                }
                .buttonStyle(.plain)
            }
            if aiDetectionEnabled {
                Button {
                    showAIDetection = true
                } label: {
                    InfoPill(
                        icon: "viewfinder",
                        text: aiMonitoringActive ? String(localized: "Monitoring", comment: "AI failure detection status: actively watching a print") : String(localized: "Idle", comment: "AI failure detection status: not currently watching a print"),
                        tint: aiMonitoringActive ? NCColor.statusPrinting : NCColor.textSecondary
                    )
                }
                .buttonStyle(.plain)
            }
            if let fw = firmwareVersion, !fw.isEmpty {
                InfoPill(icon: "cpu", text: fw)
            }
            if let hours = totalPrintHours {
                InfoPill(icon: "clock", text: "\(Int(hours))h")
            }
            if let ok = maintenanceOK {
                Button {
                    showMaintenance = true
                } label: {
                    InfoPill(
                        icon: "wrench.fill",
                        text: ok ? String(localized: "OK", comment: "Maintenance status: nothing due") : String(localized: "Due", comment: "Maintenance status: something needs attention"),
                        tint: ok ? NCColor.statusPrinting : NCColor.statusWarning
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Shows maintenance tasks", comment: "Accessibility hint on the maintenance status pill"))
            }
            if hasDoorSensor {
                InfoPill(
                    icon: doorOpen ? "door.left.hand.open" : "door.left.hand.closed",
                    text: doorOpen ? String(localized: "Door Open", comment: "Enclosed printer's chamber door status") : String(localized: "Door Closed", comment: "Enclosed printer's chamber door status"),
                    tint: doorOpen ? NCColor.statusWarning : NCColor.textSecondary
                )
            }
        }
    }
}

struct PrinterJobCard: View {
    var printerID: String
    var job: String
    var isPaused: Bool
    var progress: Double?
    var etaDescription: String?
    var estimatedFinish: Date?
    var currentLayer: Int?
    var totalLayers: Int?
    @Binding var showCoverFullscreen: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                showCoverFullscreen = true
            } label: {
                PrinterCoverImage(printerID: printerID, jobIdentity: job)
                    .frame(width: 56, height: 56)
                    .background(NCColor.well)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 8) {
                Text(job)
                    .ncFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressBar(progress: progress ?? 0, tint: isPaused ? NCColor.statusWarning : NCColor.statusPrinting)
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Text(progress ?? 0, format: .percent.precision(.fractionLength(0)))
                        if let currentLayer, let totalLayers, totalLayers > 0 {
                            Text("· layer \(currentLayer)/\(totalLayers)", comment: "Print progress in layers, e.g. '· layer 140/226'")
                        }
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 4) {
                        Text("\(etaDescription ?? "--") left", comment: "Remaining print time, e.g. '12m left'")
                        if let estimatedFinish {
                            Text("· \(estimatedFinish.formatted(date: .omitted, time: .shortened))", comment: "Clock time the print should finish")
                        }
                    }
                }
                .ncFont(size: 12, weight: .medium, relativeTo: .caption)
                .foregroundStyle(NCColor.textSecondary)
                .lineLimit(1)
            }
        }
        .padding(14)
        .glassCard()
    }
}

/// Everything about the printer's last print in one card, for whenever it isn't printing: the
/// plate render, the print's name and when it finished, whether the plate is clear for the next
/// job (with the way to say it is), and "How did it come out?" while that's still open. These
/// used to be two cards — a half-width idle card and a separate outcome card about the same
/// print.
struct PrinterLastPrintCard: View {
    var printerID: String
    var awaitingPlateClear: Bool
    @Binding var showCoverFullscreen: Bool
    @Environment(AppStore.self) private var store
    /// The print the verdict buttons were showing for when the screen opened. Kept on screen
    /// after it's answered, so a mis-tap can be changed, until the screen is left.
    @State private var askingAbout: String?

    private var lastPrint: PrintRecord? { store.printHistory.first { $0.printerID == printerID } }

    /// Asks "How did it come out?" for a print that finished recently with no answer yet — and
    /// keeps asking about one answered here.
    private var verdictRecord: PrintRecord? {
        guard let record = store.recentFinishedPrint(printerID: printerID) else { return nil }
        return record.verdict == nil || record.id == askingAbout ? record : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    showCoverFullscreen = true
                } label: {
                    PrinterCoverImage(printerID: printerID, jobIdentity: printerID)
                        .frame(width: 56, height: 56)
                        .background(NCColor.well)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 3) {
                    if let lastPrint {
                        Group {
                            if let finishedAt = lastPrint.finishedAt {
                                Text("Last print · \(finishedAt.formatted(.relative(presentation: .named)))", comment: "Printer screen: when the last print finished")
                            } else {
                                Text("Last print", comment: "Printer screen: heading for the last print")
                            }
                        }
                        .ncFont(size: 12, relativeTo: .caption)
                        .foregroundStyle(NCColor.textTertiary)
                        HStack(spacing: 6) {
                            Text(lastPrint.name)
                                .ncFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let badge = outcomeBadge(lastPrint) {
                                Text(badge.text)
                                    .ncFont(size: 12, weight: .semibold, relativeTo: .caption)
                                    .foregroundStyle(badge.color)
                                    .fixedSize()
                            }
                        }
                    } else {
                        Text("No recent print", comment: "Printer screen: no print history for this printer")
                            .ncFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                            .foregroundStyle(.white)
                    }
                    Label(
                        awaitingPlateClear
                            ? String(localized: "Plate not clear", comment: "Plate status: parts still on the build plate from the last print")
                            : String(localized: "Plate clear", comment: "Plate status: build plate is empty and ready"),
                        systemImage: awaitingPlateClear ? "square.dashed" : "checkmark.square"
                    )
                    .ncFont(size: 12.5, weight: .medium, relativeTo: .caption)
                    .foregroundStyle(awaitingPlateClear ? NCColor.statusWarning : NCColor.statusPrinting)
                }
                Spacer(minLength: 0)
            }

            if let verdictRecord {
                VerdictPicker(record: verdictRecord)
                    .onAppear { askingAbout = verdictRecord.id }
            }

            if awaitingPlateClear {
                Button {
                    store.clearPlate(printerID)
                } label: {
                    HStack {
                        Spacer()
                        Image(systemName: "square.dashed")
                        Text("Mark plate as cleared")
                        Spacer()
                    }
                    .ncFont(size: 13, weight: .semibold, relativeTo: .footnote)
                    .foregroundStyle(NCColor.statusWarning)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(NCColor.statusWarning.opacity(0.15)))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard()
    }

    /// The outcome next to the name, when there's one worth stating and the verdict buttons
    /// aren't already showing it.
    private func outcomeBadge(_ record: PrintRecord) -> (text: String, color: Color)? {
        switch record.outcome {
        case .failed: return (String(localized: "Failed", comment: "Print history status"), NCColor.statusError)
        case .cancelled: return (String(localized: "Cancelled", comment: "Print history status"), NCColor.statusWarning)
        default: break
        }
        guard verdictRecord?.id != record.id else { return nil }
        switch record.verdict {
        case .good?: return (String(localized: "Good", comment: "Print verdict"), NCColor.statusPrinting)
        case .reject?: return (String(localized: "Reject", comment: "Print verdict"), NCColor.statusError)
        case nil: return nil
        }
    }
}

struct PrinterControlsRow: View {
    var printerID: String
    var state: PrinterState
    var lightOn: Bool
    /// See `Printer.lacksDeveloperMode`: pause/resume and stop are disabled, with a note saying
    /// why; the light keeps working without Developer LAN mode.
    var lacksDeveloperMode: Bool
    @Binding var showLiveStream: Bool
    @Environment(AppStore.self) private var store
    /// Stop cancels the print outright and it can't be resumed, so it always asks first — a stray
    /// tap next to Pause shouldn't be able to end a job.
    @State private var isConfirmingStop = false
    @State private var showsLANModeDetail = false

    private var hasJob: Bool { state == .printing || state == .paused }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            controls
            // Only while there's a print it would block: on an idle printer, pause and stop
            // aren't shown at all.
            if lacksDeveloperMode && hasJob {
                Button {
                    withAnimation(.snappy) { showsLANModeDetail.toggle() }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "lock.fill")
                        Text("Developer LAN mode off · pause and stop unavailable", comment: "One-line note under printer controls without Developer LAN mode")
                        Image(systemName: showsLANModeDetail ? "chevron.up.circle" : "info.circle")
                    }
                    .ncFont(size: 12, relativeTo: .caption)
                    .foregroundStyle(NCColor.textTertiary)
                }
                .buttonStyle(.plain)
                if showsLANModeDetail {
                    Text("Without Developer LAN mode the printer won't accept pause, stop, homing or RFID re-reads from NozzleCast. Turn it on in the printer's LAN settings.", comment: "Explains why printer controls are disabled")
                        .ncFont(size: 12, relativeTo: .caption)
                        .foregroundStyle(NCColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The controls that apply now: pause or resume and stop while there's a print; the camera
    /// in their place otherwise, rather than two greyed-out buttons.
    private var controls: some View {
        HStack(spacing: 16) {
            if hasJob {
                ControlButton(
                    systemName: state == .printing ? "pause.fill" : "play.fill",
                    label: state == .printing
                        ? String(localized: "Pause", comment: "Printer control button")
                        : String(localized: "Resume", comment: "Printer control button")
                ) {
                    store.togglePause(printerID)
                }
                .disabled(lacksDeveloperMode)
                ControlButton(systemName: "stop.fill", label: String(localized: "Stop", comment: "Printer control button")) {
                    isConfirmingStop = true
                }
                .disabled(lacksDeveloperMode)
                .confirmationDialog(
                    Text("Stop this print?", comment: "Stop print confirmation title"),
                    isPresented: $isConfirmingStop,
                    titleVisibility: .visible
                ) {
                    Button(role: .destructive) {
                        store.stop(printerID)
                    } label: {
                        Text("Stop Print", comment: "Stop print confirmation button")
                    }
                    Button(role: .cancel) {} label: { Text("Cancel") }
                } message: {
                    Text("The print will be cancelled and can't be resumed.", comment: "Stop print confirmation message")
                }
            }
            ControlButton(systemName: "lightbulb.fill", label: String(localized: "Light", comment: "Printer control button"), isActive: lightOn) {
                store.toggleLight(printerID)
            }
            if !hasJob && state != .offline {
                ControlButton(systemName: "video.fill", label: String(localized: "Live", comment: "Printer control button: opens the live camera")) {
                    showLiveStream = true
                }
            }
            Menu {
                PrinterMoreMenuItems(printerID: printerID, showLiveStream: $showLiveStream)
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                    Text("More")
                        .ncFont(size: 11, weight: .medium, relativeTo: .caption2)
                        .foregroundStyle(NCColor.textSecondary)
                }
            }
            Spacer()
        }
    }
}

/// Temperatures as one row of chips. A chip shows its target only while heating toward it
/// (in amber) — at temperature, or with no target, the reading alone says it.
struct PrinterTemperaturesSection: View {
    var nozzle: TemperatureReading
    var rightNozzle: TemperatureReading?
    var bed: TemperatureReading
    var chamber: TemperatureReading?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Temperatures").sectionEyebrow()
            FlowLayout(spacing: 6, rowSpacing: 6) {
                if let rightNozzle {
                    TemperatureMetricChip(icon: "flame.fill", label: String(localized: "L", comment: "Left nozzle, in a temperature chip"), reading: nozzle)
                    TemperatureMetricChip(icon: "flame.fill", label: String(localized: "R", comment: "Right nozzle, in a temperature chip"), reading: rightNozzle)
                } else {
                    TemperatureMetricChip(icon: "flame.fill", label: String(localized: "Nozzle", comment: "Temperature reading label"), reading: nozzle)
                }
                TemperatureMetricChip(icon: "square.stack.3d.up.fill", label: String(localized: "Bed", comment: "Temperature reading label"), reading: bed)
                if let chamber {
                    TemperatureMetricChip(icon: "cube.fill", label: String(localized: "Chamber", comment: "Temperature reading label"), reading: chamber)
                }
            }
        }
    }
}

struct TemperatureMetricChip: View {
    var icon: String
    var label: String
    var reading: TemperatureReading

    /// Heating (or cooling) toward a target it hasn't reached — within a few degrees counts as
    /// there, since a reading hovers around its target.
    private var isMovingToTarget: Bool {
        guard let target = reading.target else { return false }
        return abs(reading.current - target) > 3
    }

    var body: some View {
        MetricChip(
            icon: icon,
            label: label,
            value: isMovingToTarget
                ? "\(reading.current)° → \(reading.target ?? 0)°"
                : "\(reading.current)°",
            tint: isMovingToTarget ? NCColor.statusWarning : nil
        )
    }
}

/// Fan speeds as one row of chips, each with its fan's icon.
struct PrinterFansSection: View {
    var fanSpeeds: FanSpeeds

    var body: some View {
        if fanSpeeds.partCooling != nil || fanSpeeds.auxiliary != nil || fanSpeeds.chamber != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("Fans").sectionEyebrow()
                FlowLayout(spacing: 6, rowSpacing: 6) {
                    if let speed = fanSpeeds.partCooling {
                        MetricChip(icon: "wind", label: String(localized: "Part", comment: "Part cooling fan, in a fan chip"), value: "\(speed)%")
                    }
                    if let speed = fanSpeeds.auxiliary {
                        MetricChip(icon: "arrow.up.and.down.and.arrow.left.and.right", label: String(localized: "Aux", comment: "Auxiliary fan, in a fan chip"), value: "\(speed)%")
                    }
                    if let speed = fanSpeeds.chamber {
                        MetricChip(icon: "fan.fill", label: String(localized: "Chamber", comment: "Chamber fan, in a fan chip"), value: "\(speed)%")
                    }
                }
            }
        }
    }
}

/// "🔥 Nozzle 220°" — a compact reading with its icon.
struct MetricChip: View {
    var icon: String
    var label: String
    var value: String
    var tint: Color?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint ?? NCColor.accentLight)
            Text(label)
                .foregroundStyle(NCColor.textSecondary)
            Text(value)
                .foregroundStyle(tint ?? .white)
                .monospacedDigit()
        }
        .ncFont(size: 13, weight: .medium, relativeTo: .footnote)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule().fill(NCColor.wellAlt))
        .accessibilityElement(children: .combine)
    }
}

struct PrinterAMSSection: View {
    var printerID: String
    var amsUnits: [AMSUnit]
    var isDualNozzle: Bool
    /// The slot feeding the current print (`Printer.activeTrayID`), outlined; nil outlines none.
    var activeTrayID: Int?
    @Binding var assignTray: AMSTray?
    @Environment(AppStore.self) private var store

    private var standardUnitOrder: [Int: Int] {
        Dictionary(uniqueKeysWithValues: amsUnits.filter { !$0.isHT }.enumerated().map { ($1.id, $0) })
    }

    private func dryingDetail(_ unit: AMSUnit) -> String {
        switch (unit.dryFilament, unit.dryTargetTemp) {
        case let (filament?, temp?):
            return String(localized: "\(filament) to \(temp)°C", comment: "Drying detail: filament type and target temperature, e.g. 'PLA to 55°C'")
        case let (filament?, nil):
            return filament
        case let (nil, temp?):
            return String(localized: "Target \(temp)°C", comment: "Drying detail: target temperature only")
        case (nil, nil):
            return ""
        }
    }

    var body: some View {
        let order = standardUnitOrder
        VStack(alignment: .leading, spacing: 14) {
            Text("AMS Filament").sectionEyebrow()
            ForEach(amsUnits) { unit in
                VStack(alignment: .leading, spacing: 4) {
                    if amsUnits.count > 1 || unit.humidity != nil || unit.feedsRightNozzle != nil || unit.isDrying {
                        HStack(spacing: 6) {
                            Text(unit.displayName(position: order[unit.id] ?? 0))
                                .ncFont(size: 11, weight: .semibold, relativeTo: .caption2)
                                .foregroundStyle(NCColor.textTertiary)
                            if isDualNozzle, let feedsRight = unit.feedsRightNozzle {
                                InfoPill(icon: feedsRight ? "arrow.right" : "arrow.left", text: feedsRight ? "R" : "L")
                            }
                            if unit.isDrying {
                                InfoPill(icon: "wind", text: String(localized: "Drying", comment: "AMS unit is actively running a drying cycle"), tint: NCColor.accentLight)
                            }
                            Spacer()
                            if let humidity = unit.humidity, let temp = unit.temperature {
                                Text("\(humidity)% · \(Int(temp.rounded()))°C", comment: "AMS unit humidity and temperature, e.g. '27% · 30°C'")
                                    .ncFont(size: 10.5, relativeTo: .caption2)
                                    .foregroundStyle(NCColor.textTertiary)
                            }
                        }
                        if unit.isDrying, unit.dryFilament != nil || unit.dryTargetTemp != nil {
                            Text(dryingDetail(unit))
                                .ncFont(size: 10, relativeTo: .caption2)
                                .foregroundStyle(NCColor.accentLight)
                        }
                    }
                    LazyVGrid(columns: AMSSlotGrid.columns, spacing: 8) {
                        ForEach(unit.trays) { tray in
                            Button {
                                assignTray = tray
                            } label: {
                                AMSSlotCard(
                                    spool: store.spool(tray.spoolID),
                                    slotIndex: tray.trayIndex,
                                    isActive: tray.globalID() == activeTrayID,
                                    tray: tray,
                                    fillsWidth: true
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    store.rereadRFID(printerID: printerID, amsIndex: tray.amsIndex, trayIndex: tray.trayIndex)
                                } label: {
                                    Label("Re-read RFID", systemImage: "wave.3.right")
                                }
                                // Refused by the printer without Developer LAN mode.
                                .disabled(store.printer(printerID)?.lacksDeveloperMode == true)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Four equal columns across the full width — an AMS unit's four slots fill a row, and a
/// one-slot AMS HT or the external spools line up under its first columns.
enum AMSSlotGrid {
    static let columns = Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 4)
}

struct PrinterExternalSection: View {
    var externalTrays: [AMSTray]
    var activeTrayID: Int? = nil
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("External").sectionEyebrow()
            LazyVGrid(columns: AMSSlotGrid.columns, spacing: 8) {
                ForEach(externalTrays) { tray in
                    AMSSlotCard(spool: store.spool(tray.spoolID), slotIndex: tray.trayIndex, isActive: tray.globalID(isExternal: true) == activeTrayID, tray: tray, fillsWidth: true)
                }
            }
        }
    }
}

struct PrinterNozzleRackSection: View {
    var nozzleRack: [NozzleRackSlot]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nozzle Rack").sectionEyebrow()
            FlowLayout(spacing: 8, rowSpacing: 8) {
                ForEach(nozzleRack) { slot in
                    NozzleRackChip(slot: slot)
                }
            }
        }
    }
}

struct PrinterPowerSection: View {
    var printerID: String
    var smartPlug: SmartPlugInfo
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Power").sectionEyebrow()
            HStack(spacing: 12) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(smartPlug.isOn ? NCColor.statusPrinting : NCColor.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(smartPlug.name)
                        .ncFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                        .foregroundStyle(.white)
                    if let watts = smartPlug.watts {
                        Text("\(watts.formatted(.number.precision(.fractionLength(0))))W")
                            .ncFont(size: 12, relativeTo: .caption)
                            .foregroundStyle(NCColor.textTertiary)
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { smartPlug.isOn },
                    set: { _ in store.toggleSmartPlug(printerID) }
                ))
                .labelsHidden()
                .tint(NCColor.accent)
            }
        }
        .padding(14)
        .glassCard()
    }
}

#Preview("Printing") {
    NavigationStack {
        PrinterDetailView(printerID: MockData.workshopX1C)
    }
    .environment(AppStore(config: BambuddyConfig()))
    .preferredColorScheme(.dark)
}

#Preview("Paused") {
    NavigationStack {
        PrinterDetailView(printerID: MockData.officeP1S)
    }
    .environment(AppStore(config: BambuddyConfig()))
    .preferredColorScheme(.dark)
}
