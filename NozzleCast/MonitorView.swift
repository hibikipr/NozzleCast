import SwiftUI

struct MonitorView: View {
    @Environment(AppStore.self) private var store
    @State private var showNotifications = false

    private var printingCount: Int { store.printers.filter { $0.state == .printing }.count }

    private var isConnecting: Bool { store.isLoadingPrinters }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("NozzleCast")
                                .ncFont(size: 34, weight: .bold, relativeTo: .largeTitle)
                            Group {
                                if isConnecting {
                                    Text("Connecting to Bambuddy…")
                                } else {
                                    Text("\(printingCount) printing · \(store.printers.count) printers")
                                }
                            }
                            .ncFont(size: 15, relativeTo: .subheadline)
                            .foregroundStyle(NCColor.textSecondary)
                        }
                        Spacer()
                        Button {
                            showNotifications = true
                        } label: {
                            Image(systemName: "bell")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(NCColor.cardFill))
                        }
                        .padding(.top, 10)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

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
                                PrinterCard(printer: printer)
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
            .refreshable { await store.refresh() }
            .navigationDestination(for: String.self) { id in
                PrinterDetailView(printerID: id)
            }
            .sheet(isPresented: $showNotifications) {
                NavigationStack {
                    NotificationsView()
                }
            }
        }
    }
}

struct PrinterCard: View {
    var printer: Printer
    @Environment(AppStore.self) private var store
    @State private var isCameraLive = false

    var body: some View {
        HStack(spacing: 12) {
            thumbnail

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(printer.name)
                        .ncFont(size: 16, weight: .semibold, relativeTo: .headline)
                        .foregroundStyle(.white)
                    Spacer()
                    HStack(spacing: 5) {
                        StatusDot(state: printer.state)
                        Text(printer.state.label)
                            .ncFont(size: 13, weight: .medium, relativeTo: .footnote)
                            .foregroundStyle(NCColor.textSecondary)
                    }
                }

                if printer.state == .printing || printer.state == .paused, let job = printer.jobFileName {
                    Text(job)
                        .ncFont(size: 12.5, relativeTo: .caption)
                        .foregroundStyle(NCColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ProgressBar(progress: printer.progress ?? 0)
                    HStack {
                        Text(printer.progress ?? 0, format: .percent.precision(.fractionLength(0)))
                        Text("·")
                        Text("\(printer.etaDescription ?? "--") left", comment: "Remaining print time, e.g. '12m left'")
                    }
                    .ncFont(size: 12, weight: .medium, relativeTo: .caption)
                    .foregroundStyle(NCColor.textTertiary)
                    if !printer.allTrays.isEmpty {
                        FlowLayout(spacing: 6, rowSpacing: 6) {
                            ForEach(printer.allTrays) { tray in
                                let spool = store.spool(tray.spoolID)
                                Circle()
                                    .fill(spool.map { Color(hex: $0.colorHex) } ?? Color.white.opacity(0.08))
                                    .frame(width: 11, height: 11)
                            }
                        }
                    }
                } else if !printer.allTrays.isEmpty {
                    FlowLayout(spacing: 7, rowSpacing: 7) {
                        ForEach(printer.allTrays) { tray in
                            let spool = store.spool(tray.spoolID)
                            Circle()
                                .fill(spool.map { Color(hex: $0.colorHex) } ?? Color.white.opacity(0.08))
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
            if printer.state == .printing {
                LiveCameraView(printerID: printer.id, pollInterval: 5, coverFallbackJobIdentity: printer.jobFileName ?? printer.id, isShowingLiveFrame: $isCameraLive)
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PrinterThumbnailImage(assetName: printer.imageAssetName)
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
