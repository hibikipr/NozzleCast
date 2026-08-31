import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var showConnectionSheet = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showConnectionSheet = true
                    } label: {
                        settingsRow(
                            title: "Server",
                            value: store.config.isConfigured ? store.config.serverURLString : "Not configured"
                        )
                    }
                    if store.config.isConfigured {
                        Button {
                            showConnectionSheet = true
                        } label: {
                            settingsRow(title: "API Key", value: store.config.maskedAPIKey)
                        }
                        HStack {
                            Text("Status")
                                .foregroundStyle(.white)
                            Spacer()
                            statusIndicator
                        }
                    }
                } header: {
                    Text("Bambuddy Server")
                } footer: {
                    Text(footerText)
                }

                Section("Printers") {
                    if store.printers.isEmpty {
                        Text(store.isRefreshing ? "Loading…" : "No printers found.")
                            .foregroundStyle(NCColor.textTertiary)
                    }
                    ForEach(store.printers) { printer in
                        NavigationLink(value: printer.id) {
                            HStack(spacing: 12) {
                                PrinterThumbnailImage(assetName: printer.imageAssetName)
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
            .navigationDestination(for: String.self) { id in
                PrinterDetailView(printerID: id)
            }
            .refreshable { await store.refresh() }
            .sheet(isPresented: $showConnectionSheet) {
                BambuddyConnectionSheet()
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch store.connectionStatus {
        case .connected:
            HStack(spacing: 6) {
                Circle().fill(NCColor.statusPrinting).frame(width: 6, height: 6)
                Text("Connected").foregroundStyle(NCColor.textSecondary)
            }
        case .connecting:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Connecting…").foregroundStyle(NCColor.textSecondary)
            }
        case .failed:
            HStack(spacing: 6) {
                Circle().fill(NCColor.statusError).frame(width: 6, height: 6)
                Text("Connection failed").foregroundStyle(NCColor.textSecondary)
            }
        case .notConfigured:
            HStack(spacing: 6) {
                Circle().fill(NCColor.statusOffline).frame(width: 6, height: 6)
                Text("Not connected").foregroundStyle(NCColor.textSecondary)
            }
        }
    }

    private var footerText: String {
        switch store.connectionStatus {
        case .connected:
            var granted: [String] = []
            if store.grantedPermissions.contains("inventory:update") || store.grantedPermissions.contains("inventory:create") {
                granted.append("Manage Inventory")
            }
            if store.grantedPermissions.contains("printers:read") {
                granted.append("Read Status")
            }
            if store.grantedPermissions.contains("printers:control") {
                granted.append("Printer Control")
            }
            return granted.isEmpty ? "Connected." : "\(granted.joined(separator: ", ")) permissions granted."
        case .failed(let message):
            return "Couldn't connect: \(message)"
        case .connecting:
            return "Connecting to your Bambuddy server…"
        case .notConfigured:
            return "Showing demo data. Tap Server to connect to your Bambuddy instance."
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
