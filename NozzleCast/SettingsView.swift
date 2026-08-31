import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationStack {
            List {
                Section {
                    settingsRow(title: "Server", value: "bambuddy.local:8000")
                    settingsRow(title: "API Key", value: "••••••••3f2c")
                    HStack {
                        Text("Status")
                            .foregroundStyle(.white)
                        Spacer()
                        HStack(spacing: 6) {
                            Circle().fill(NCColor.statusPrinting).frame(width: 6, height: 6)
                            Text("Connected")
                                .foregroundStyle(NCColor.textSecondary)
                        }
                    }
                } header: {
                    Text("Bambuddy Server")
                } footer: {
                    Text("Manage Inventory, Read Status permissions granted.")
                }

                Section("Printers") {
                    ForEach(store.printers) { printer in
                        NavigationLink(value: printer.id) {
                            HStack(spacing: 12) {
                                Image(printer.imageAssetName)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 30, height: 30)
                                    .padding(4)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(NCColor.well))
                                Text(printer.name)
                                    .foregroundStyle(.white)
                                Spacer()
                                Text(printer.model)
                                    .foregroundStyle(NCColor.textTertiary)
                            }
                        }
                    }
                }

                Section {
                    VStack(spacing: 8) {
                        Image("AppIconSource")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        Text("NoozleCast 1.0.0")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("Local-first control for your farm.")
                            .font(.system(size: 12))
                            .foregroundStyle(NCColor.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(NCColor.canvasBackground.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationDestination(for: UUID.self) { id in
                PrinterDetailView(printerID: id)
            }
        }
    }

    private func settingsRow(title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.white)
            Spacer()
            Text(value).foregroundStyle(NCColor.textSecondary)
        }
    }
}
