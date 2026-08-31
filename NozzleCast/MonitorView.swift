import SwiftUI

struct MonitorView: View {
    @Environment(AppStore.self) private var store

    private var printingCount: Int { store.printers.filter { $0.state == .printing }.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NoozleCast")
                            .font(.system(size: 34, weight: .bold))
                        Text("\(printingCount) printing · \(store.printers.count) printers")
                            .font(.system(size: 15))
                            .foregroundStyle(NCColor.textSecondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                    ForEach(store.printers) { printer in
                        NavigationLink(value: printer.id) {
                            PrinterCard(printer: printer)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 100)
            }
            .background(NCColor.canvasBackground.ignoresSafeArea())
            .navigationBarHidden(true)
            .navigationDestination(for: UUID.self) { id in
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
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    HStack(spacing: 5) {
                        StatusDot(state: printer.state)
                        Text(printer.state.label)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(NCColor.textSecondary)
                    }
                }

                if printer.state == .printing || printer.state == .paused, let job = printer.jobFileName {
                    Text(job)
                        .font(.system(size: 12.5))
                        .foregroundStyle(NCColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ProgressBar(progress: printer.progress ?? 0)
                    HStack {
                        Text("\(Int((printer.progress ?? 0) * 100))%")
                        Text("·")
                        Text("\(printer.etaDescription ?? "--") left")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NCColor.textTertiary)
                } else {
                    HStack(spacing: 7) {
                        ForEach(0..<4, id: \.self) { i in
                            let spool = store.spool(printer.amsSlotSpoolIDs[i])
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
                Image(systemName: "camera.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(printer.imageAssetName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
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
