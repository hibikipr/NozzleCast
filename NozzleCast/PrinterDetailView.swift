import SwiftUI

struct PrinterDetailView: View {
    var printerID: String
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var assignTray: AMSTray?

    private var printer: Printer? { store.printer(printerID) }

    var body: some View {
        if let printer {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    videoHeader(printer)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(printer.name)
                            .font(.system(size: 24, weight: .bold))
                        Text(printer.statusSubtitle)
                            .font(.system(size: 15))
                            .foregroundStyle(NCColor.textSecondary)
                    }
                    .padding(.horizontal, 16)

                    if printer.state == .printing || printer.state == .paused, let job = printer.jobFileName {
                        jobCard(printer: printer, job: job)
                            .padding(.horizontal, 16)
                    }

                    controlsRow(printer)
                        .padding(.horizontal, 16)

                    temperaturesSection(printer)
                        .padding(.horizontal, 16)

                    if !printer.amsUnits.isEmpty {
                        amsSection(printer)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 32)
                    }
                }
            }
            .background(NCColor.canvasBackground.ignoresSafeArea())
            .navigationBarHidden(true)
            .toolbar(.hidden, for: .tabBar)
            .sheet(item: $assignTray) { tray in
                AMSAssignSheet(printerID: printerID, amsIndex: tray.amsIndex, trayIndex: tray.trayIndex)
            }
        } else {
            ContentUnavailableView("Printer not found", systemImage: "printer.fill")
        }
    }

    @ViewBuilder
    private func videoHeader(_ printer: Printer) -> some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "#2a2a2a"), Color(hex: "#141414")], startPoint: .top, endPoint: .bottom)
            if printer.state == .offline {
                Image(systemName: "camera.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.3))
            } else {
                LiveCameraView(printerID: printer.id, pollInterval: 3)
                    .font(.system(size: 44))
            }
        }
        .frame(height: 250)
        .overlay(alignment: .topLeading) {
            HStack {
                GlassIconButton(systemName: "chevron.left") { dismiss() }
                Spacer()
                Menu {
                    moreMenuItems(printer)
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
            (printer.state == .offline
                ? AnyView(offlinePill)
                : AnyView(LiveBadge().scaleEffect(1.3)))
                .padding(.top, 60)
                .padding(.leading, 16)
        }
        .clipped()
    }

    private var offlinePill: some View {
        Text("OFFLINE")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.55)))
    }

    private func jobCard(printer: Printer, job: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(job)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(Int((printer.progress ?? 0) * 100))%")
                    .font(.system(size: 15, weight: .bold))
            }
            ProgressBar(progress: printer.progress ?? 0)
            Text("\(printer.etaDescription ?? "--") remaining")
                .font(.system(size: 12.5))
                .foregroundStyle(NCColor.textSecondary)
        }
        .padding(14)
        .glassCard()
    }

    private func controlsRow(_ printer: Printer) -> some View {
        HStack(spacing: 16) {
            ControlButton(
                systemName: printer.state == .printing ? "pause.fill" : "play.fill",
                label: printer.state == .printing ? "Pause" : (printer.state == .paused ? "Resume" : "Start")
            ) {
                store.togglePause(printer.id)
            }
            ControlButton(systemName: "stop.fill", label: "Stop") {
                store.stop(printer.id)
            }
            ControlButton(systemName: "lightbulb.fill", label: "Light", isActive: printer.lightOn) {
                store.toggleLight(printer.id)
            }
            Menu {
                moreMenuItems(printer)
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                    Text("More")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(NCColor.textSecondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func moreMenuItems(_ printer: Printer) -> some View {
        Button {
            Task { await store.refresh() }
        } label: {
            Label("Refresh Status", systemImage: "arrow.clockwise")
        }

        if store.isLive {
            Button {
                store.homeAxes(printer.id)
            } label: {
                Label("Home Axes", systemImage: "house")
            }

            if let url = store.webCameraURL(printerID: printer.id) {
                Button {
                    openURL(url)
                } label: {
                    Label("Open Camera in Browser", systemImage: "safari")
                }
            }
        }
    }

    private func temperaturesSection(_ printer: Printer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Temperatures").sectionEyebrow()
            HStack(spacing: 10) {
                tempChip(icon: "flame.fill", caption: "Nozzle", reading: printer.nozzle, showTarget: true)
                tempChip(icon: "square.stack.3d.up.fill", caption: "Bed", reading: printer.bed, showTarget: true)
                if let chamber = printer.chamber {
                    tempChip(icon: "cube.fill", caption: "Chamber", reading: chamber, showTarget: false)
                }
            }
        }
    }

    private func tempChip(icon: String, caption: String, reading: TemperatureReading, showTarget: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(NCColor.accentLight)
            if showTarget, let target = reading.target {
                Text("\(reading.current)°/\(target)°")
                    .font(.system(size: 15, weight: .semibold))
            } else {
                Text("\(reading.current)°")
                    .font(.system(size: 15, weight: .semibold))
            }
            Text(caption)
                .font(.system(size: 11.5))
                .foregroundStyle(NCColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(NCColor.wellAlt))
    }

    private func amsSection(_ printer: Printer) -> some View {
        let standardUnitOrder = Dictionary(uniqueKeysWithValues: printer.amsUnits.filter { !$0.isHT }.enumerated().map { ($1.id, $0) })
        return VStack(alignment: .leading, spacing: 14) {
            Text("AMS Filament").sectionEyebrow()
            ForEach(printer.amsUnits) { unit in
                VStack(alignment: .leading, spacing: 8) {
                    if printer.amsUnits.count > 1 {
                        Text(unit.displayName(position: standardUnitOrder[unit.id] ?? 0))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(NCColor.textTertiary)
                    }
                    HStack(spacing: 8) {
                        ForEach(unit.trays) { tray in
                            Button {
                                assignTray = tray
                            } label: {
                                AMSSlotCard(
                                    spool: store.spool(tray.spoolID),
                                    slotIndex: tray.trayIndex,
                                    isActive: tray.spoolID != nil && printer.state == .printing
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}
