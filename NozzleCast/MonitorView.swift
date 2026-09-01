import SwiftUI

struct MonitorView: View {
    @Environment(AppStore.self) private var store

    private var printingCount: Int { store.printers.filter { $0.state == .printing }.count }

    private var isConnecting: Bool {
        if case .connecting = store.connectionStatus, store.printers.isEmpty { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NoozleCast")
                            .ncFont(size: 34, weight: .bold, relativeTo: .largeTitle)
                        Text(isConnecting ? "Connecting to Bambuddy…" : "\(printingCount) printing · \(store.printers.count) printers")
                            .ncFont(size: 15, relativeTo: .subheadline)
                            .foregroundStyle(NCColor.textSecondary)
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
        }
    }
}

struct PrinterCard: View {
    var printer: Printer
    @Environment(AppStore.self) private var store

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
                        Text("\(Int((printer.progress ?? 0) * 100))%")
                        Text("·")
                        Text("\(printer.etaDescription ?? "--") left")
                    }
                    .ncFont(size: 12, weight: .medium, relativeTo: .caption)
                    .foregroundStyle(NCColor.textTertiary)
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
                .fill(NCColor.well)
            if printer.state == .printing {
                LiveCameraView(printerID: printer.id, pollInterval: 5)
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
        .overlay(alignment: .topLeading) {
            if printer.state == .printing {
                LiveBadge().padding(4)
            }
        }
    }
}
