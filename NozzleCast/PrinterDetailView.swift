import SwiftUI

struct PrinterDetailView: View {
    var printerID: String
    @Environment(AppStore.self) private var store
    @State private var assignTray: AMSTray?
    @State private var showWarnings = false
    @State private var showCoverFullscreen = false
    @State private var isCameraLive = false
    @State private var showAIDetection = false
    @State private var showLiveStream = false

    private var printer: Printer? { store.printer(printerID) }

    var body: some View {
        if let printer {
            PrinterDetailContent(
                printer: printer,
                isCameraLive: $isCameraLive,
                assignTray: $assignTray,
                showWarnings: $showWarnings,
                showAIDetection: $showAIDetection,
                showCoverFullscreen: $showCoverFullscreen,
                showLiveStream: $showLiveStream
            )
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
    @Binding var isCameraLive: Bool
    @Binding var assignTray: AMSTray?
    @Binding var showWarnings: Bool
    @Binding var showAIDetection: Bool
    @Binding var showCoverFullscreen: Bool
    @Binding var showLiveStream: Bool
    @Environment(AppStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PrinterVideoHeader(printerID: printer.id, state: printer.state, jobFileName: printer.jobFileName, isCameraLive: $isCameraLive, showLiveStream: $showLiveStream)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text(printer.name)
                            .ncFont(size: 24, weight: .bold, relativeTo: .title)
                        // Feedback for the "Refresh Status" menu item, which otherwise changed
                        // nothing visible when the data was already current.
                        if store.isUserRefreshing {
                            ProgressView().controlSize(.small).tint(NCColor.accentLight)
                            Text("Refreshing…", comment: "Shown next to the printer name while a user-requested refresh runs")
                                .ncFont(size: 12, relativeTo: .caption)
                                .foregroundStyle(NCColor.textTertiary)
                        }
                    }
                    Text(printer.statusSubtitle)
                        .ncFont(size: 15, relativeTo: .subheadline)
                        .foregroundStyle(NCColor.textSecondary)
                }
                .padding(.horizontal, 16)

                PrinterInfoPillRow(
                    model: printer.model,
                    wifiSignalDBm: printer.wifiSignalDBm,
                    hmsErrorCount: printer.hmsErrors.count,
                    hmsWorstLevel: printer.hmsErrors.map(\.level).min(),
                    aiDetectionEnabled: printer.aiDetectionEnabled,
                    aiMonitoringActive: printer.aiMonitoringActive,
                    firmwareVersion: printer.firmwareVersion,
                    totalPrintHours: printer.totalPrintHours,
                    maintenanceOK: printer.maintenanceOK,
                    doorOpen: printer.doorOpen,
                    showWarnings: $showWarnings,
                    showAIDetection: $showAIDetection
                )
                .padding(.horizontal, 16)

                if printer.state == .printing || printer.state == .paused, let job = printer.jobFileName {
                    PrinterJobCard(printerID: printer.id, job: job, progress: printer.progress, etaDescription: printer.etaDescription, showCoverFullscreen: $showCoverFullscreen)
                        .padding(.horizontal, 16)
                } else if printer.state != .offline {
                    PrinterIdleStatusCard(printerID: printer.id, stateLabel: printer.state.label, awaitingPlateClear: printer.awaitingPlateClear, showCoverFullscreen: $showCoverFullscreen)
                        .padding(.horizontal, 16)
                }

                PrinterControlsRow(printerID: printer.id, state: printer.state, lightOn: printer.lightOn, lacksDeveloperMode: printer.lacksDeveloperMode, showLiveStream: $showLiveStream)
                    .padding(.horizontal, 16)

                PrinterTemperaturesSection(nozzle: printer.nozzle, rightNozzle: printer.rightNozzle, bed: printer.bed, chamber: printer.chamber)
                    .padding(.horizontal, 16)

                PrinterFansSection(fanSpeeds: printer.fanSpeeds)
                    .padding(.horizontal, 16)

                if !printer.amsUnits.isEmpty {
                    PrinterAMSSection(printerID: printer.id, amsUnits: printer.amsUnits, isDualNozzle: printer.isDualNozzle, isPrinting: printer.state == .printing, assignTray: $assignTray)
                        .padding(.horizontal, 16)
                }

                if !printer.externalTrays.isEmpty {
                    PrinterExternalSection(externalTrays: printer.externalTrays)
                        .padding(.horizontal, 16)
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
        .background(NCColor.canvasBackground.ignoresSafeArea())
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .tabBar)
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "#2a2a2a"), Color(hex: "#141414")], startPoint: .top, endPoint: .bottom)
            if state == .offline {
                Image(systemName: "camera.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.3))
            } else {
                LiveCameraView(printerID: printerID, pollInterval: 3, showsErrorDetail: true, coverFallbackJobIdentity: jobFileName ?? printerID, isShowingLiveFrame: $isCameraLive)
                    .font(.system(size: 44))
            }
        }
        .frame(height: 250)
        .overlay(alignment: .topLeading) {
            HStack {
                GlassIconButton(systemName: "chevron.left") { dismiss() }
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
                    InfoPill(icon: (hmsWorstLevel ?? .warning).symbol, text: "\(hmsErrorCount)", tint: (hmsWorstLevel ?? .warning).color)
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
                InfoPill(
                    icon: "wrench.fill",
                    text: ok ? String(localized: "OK", comment: "Maintenance status: nothing due") : String(localized: "Due", comment: "Maintenance status: something needs attention"),
                    tint: ok ? NCColor.statusPrinting : NCColor.statusWarning
                )
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
    var progress: Double?
    var etaDescription: String?
    @Binding var showCoverFullscreen: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                showCoverFullscreen = true
            } label: {
                PrinterCoverImage(printerID: printerID, jobIdentity: job)
                    .frame(width: 52, height: 52)
                    .background(NCColor.well)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(job)
                        .ncFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(progress ?? 0, format: .percent.precision(.fractionLength(0)))
                        .ncFont(size: 15, weight: .bold, relativeTo: .subheadline)
                }
                ProgressBar(progress: progress ?? 0)
                Text("\(etaDescription ?? "--") remaining", comment: "Remaining print time, e.g. '12m remaining'")
                    .ncFont(size: 12.5, relativeTo: .caption)
                    .foregroundStyle(NCColor.textSecondary)
            }
        }
        .padding(14)
        .glassCard()
    }
}

/// The idle/finished equivalent of `PrinterJobCard` — no active job, but still worth showing the
/// last plate render and whether it needs clearing before the next print can start.
struct PrinterIdleStatusCard: View {
    var printerID: String
    var stateLabel: String
    var awaitingPlateClear: Bool
    @Binding var showCoverFullscreen: Bool
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    showCoverFullscreen = true
                } label: {
                    PrinterCoverImage(printerID: printerID, jobIdentity: printerID)
                        .frame(width: 52, height: 52)
                        .background(NCColor.well)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(stateLabel)
                            .ncFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                        InfoPill(
                            icon: awaitingPlateClear ? "square.dashed" : "checkmark.square",
                            text: awaitingPlateClear ? String(localized: "Plate not Clear", comment: "Plate status: parts still on the build plate from the last print") : String(localized: "Plate Clear", comment: "Plate status: build plate is empty and ready"),
                            tint: awaitingPlateClear ? NCColor.statusWarning : NCColor.statusPrinting
                        )
                    }
                    Text("No active job")
                        .ncFont(size: 12.5, relativeTo: .caption)
                        .foregroundStyle(NCColor.textSecondary)
                }
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
        .padding(14)
        .glassCard()
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            controls
            if lacksDeveloperMode {
                Label {
                    Text("Developer LAN mode is off on this printer, so it won't accept pause, stop, homing or RFID re-reads from NozzleCast. Turn it on in the printer's LAN settings.", comment: "Explains why printer controls are disabled")
                } icon: {
                    Image(systemName: "lock.fill")
                }
                .ncFont(size: 12, relativeTo: .caption)
                .foregroundStyle(NCColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            ControlButton(
                systemName: state == .printing ? "pause.fill" : "play.fill",
                label: state == .printing
                    ? String(localized: "Pause", comment: "Printer control button")
                    : (state == .paused
                        ? String(localized: "Resume", comment: "Printer control button")
                        : String(localized: "Start", comment: "Printer control button"))
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
            ControlButton(systemName: "lightbulb.fill", label: String(localized: "Light", comment: "Printer control button"), isActive: lightOn) {
                store.toggleLight(printerID)
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

struct PrinterTemperaturesSection: View {
    var nozzle: TemperatureReading
    var rightNozzle: TemperatureReading?
    var bed: TemperatureReading
    var chamber: TemperatureReading?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Temperatures").sectionEyebrow()
            HStack(spacing: 10) {
                if let rightNozzle {
                    TemperatureChip(icon: "flame.fill", caption: String(localized: "Nozzle L", comment: "Left nozzle temperature reading label"), reading: nozzle, showTarget: true)
                    TemperatureChip(icon: "flame.fill", caption: String(localized: "Nozzle R", comment: "Right nozzle temperature reading label"), reading: rightNozzle, showTarget: true)
                } else {
                    TemperatureChip(icon: "flame.fill", caption: String(localized: "Nozzle", comment: "Temperature reading label"), reading: nozzle, showTarget: true)
                }
                TemperatureChip(icon: "square.stack.3d.up.fill", caption: String(localized: "Bed", comment: "Temperature reading label"), reading: bed, showTarget: true)
                if let chamber {
                    TemperatureChip(icon: "cube.fill", caption: String(localized: "Chamber", comment: "Temperature reading label"), reading: chamber, showTarget: false)
                }
            }
        }
    }
}

struct TemperatureChip: View {
    var icon: String
    var caption: String
    var reading: TemperatureReading
    var showTarget: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(NCColor.accentLight)
            if showTarget, let target = reading.target {
                Text("\(reading.current)°/\(target)°")
                    .ncFont(size: 15, weight: .semibold, relativeTo: .subheadline)
            } else {
                Text("\(reading.current)°")
                    .ncFont(size: 15, weight: .semibold, relativeTo: .subheadline)
            }
            Text(caption)
                .ncFont(size: 11.5, relativeTo: .caption)
                .foregroundStyle(NCColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(NCColor.wellAlt))
    }
}

struct PrinterFansSection: View {
    var fanSpeeds: FanSpeeds

    var body: some View {
        if fanSpeeds.partCooling != nil || fanSpeeds.auxiliary != nil || fanSpeeds.chamber != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("Fans").sectionEyebrow()
                HStack(spacing: 10) {
                    FanSpeedChip(icon: "wind", caption: String(localized: "Part Cooling", comment: "Fan speed label"), percent: fanSpeeds.partCooling)
                    FanSpeedChip(icon: "arrow.up.and.down.and.arrow.left.and.right", caption: String(localized: "Auxiliary", comment: "Fan speed label"), percent: fanSpeeds.auxiliary)
                    FanSpeedChip(icon: "fan.fill", caption: String(localized: "Chamber", comment: "Fan speed label"), percent: fanSpeeds.chamber)
                }
            }
        }
    }
}

struct PrinterAMSSection: View {
    var printerID: String
    var amsUnits: [AMSUnit]
    var isDualNozzle: Bool
    var isPrinting: Bool
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
                    HStack(spacing: 8) {
                        ForEach(unit.trays) { tray in
                            Button {
                                assignTray = tray
                            } label: {
                                AMSSlotCard(
                                    spool: store.spool(tray.spoolID),
                                    slotIndex: tray.trayIndex,
                                    isActive: tray.spoolID != nil && isPrinting,
                                    tray: tray
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

struct PrinterExternalSection: View {
    var externalTrays: [AMSTray]
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("External").sectionEyebrow()
            HStack(spacing: 8) {
                ForEach(externalTrays) { tray in
                    AMSSlotCard(spool: store.spool(tray.spoolID), slotIndex: tray.trayIndex, tray: tray)
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
