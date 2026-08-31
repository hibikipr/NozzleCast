import SwiftUI

struct AssignPickerSheet: View {
    var spool: Spool
    var onFinished: () -> Void

    @Environment(AppStore.self) private var store
    @State private var selectedPrinterID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 16)

            if let selectedPrinterID {
                slotStep(printerID: selectedPrinterID)
            } else {
                printerStep
            }
        }
        .background(Color(hex: "#212121").ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(24)
        .presentationDragIndicator(.hidden)
    }

    private var printerStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a Printer")
                .font(.system(size: 17, weight: .bold))
                .padding(.horizontal, 20)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.printers) { printer in
                        Button {
                            selectedPrinterID = printer.id
                        } label: {
                            HStack(spacing: 12) {
                                Image(printer.imageAssetName)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 30, height: 30)
                                    .padding(4)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(NCColor.well))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(printer.name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.white)
                                    Text(printer.model)
                                        .font(.system(size: 12))
                                        .foregroundStyle(NCColor.textTertiary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(NCColor.textTertiary)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 20)
                    }
                }
            }
        }
    }

    private func slotStep(printerID: UUID) -> some View {
        let printer = store.printer(printerID)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button {
                    selectedPrinterID = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .foregroundStyle(NCColor.textSecondary)
                }
                Text("\(printer?.name ?? "Printer") · Choose a Slot")
                    .font(.system(size: 17, weight: .bold))
            }
            .padding(.horizontal, 20)

            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { i in
                    Button {
                        store.assign(spoolID: spool.id, toPrinter: printerID, slot: i)
                        onFinished()
                    } label: {
                        AMSSlotCard(spool: store.spool(printer?.amsSlotSpoolIDs[i]), slotIndex: i)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)

            Spacer()
        }
    }
}
