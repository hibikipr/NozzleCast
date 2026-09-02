import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum AppIconOption: String, CaseIterable, Identifiable {
    /// The primary icon — Steel's image now lives in `AppIcon.appiconset` itself.
    case `default`
    /// The original dark icon, formerly the primary — kept on as an alternate since Steel took
    /// over the primary slot.
    case classic
    case snow
    case midnight
    case ice

    var id: String { rawValue }

    /// `nil` selects the primary icon — `UIApplication.setAlternateIconName(nil)` is how you
    /// switch back to it, it isn't itself a registered alternate name.
    var alternateIconName: String? {
        switch self {
        case .default: nil
        case .classic: "AppIcon-Classic"
        case .snow: "AppIcon-Snow"
        case .midnight: "AppIcon-Midnight"
        case .ice: "AppIcon-Ice"
        }
    }

    var assetName: String {
        switch self {
        case .default: "AppIconSource"
        case .classic: "AppIconClassicSource"
        case .snow: "AppIconSnowSource"
        case .midnight: "AppIconMidnightSource"
        case .ice: "AppIconIceSource"
        }
    }

    var title: String {
        switch self {
        case .default: String(localized: "Default", comment: "App icon option name")
        case .classic: String(localized: "Classic", comment: "App icon option name")
        case .snow: String(localized: "Snow", comment: "App icon option name")
        case .midnight: String(localized: "Midnight", comment: "App icon option name")
        case .ice: String(localized: "Ice", comment: "App icon option name")
        }
    }
}

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var showConnectionSheet = false
    @State private var showFileImporter = false
    @State private var importError: String?
    @State private var pushManager = PushNotificationManager.shared
    @State private var selectedIcon: AppIconOption = AppIconOption.allCases.first { $0.alternateIconName == UIApplication.shared.alternateIconName } ?? .default

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showFileImporter = true
                    } label: {
                        settingsRow(
                            title: String(localized: "Firebase Config", comment: "Settings row label"),
                            value: FirebaseConfigStore.isConfigured
                                ? (FirebaseConfigStore.projectID ?? String(localized: "Imported", comment: "Settings row value when Firebase config is set but has no project id"))
                                : String(localized: "Not imported", comment: "Settings row value when no Firebase config is set")
                        )
                    }
                    if FirebaseConfigStore.isConfigured {
                        Button {
                            Task {
                                try? await pushManager.requestAuthorization()
                                await store.discoverAndSubscribeNtfy()
                            }
                        } label: {
                            settingsRow(
                                title: String(localized: "Push Notifications", comment: "Settings row label"),
                                value: pushManager.authorizationStatus == .authorized
                                    ? (pushManager.subscribedTopic != nil
                                        ? String(localized: "Enabled", comment: "Settings row value: push notifications on")
                                        : String(localized: "Tap to subscribe", comment: "Settings row value: needs subscription"))
                                    : String(localized: "Tap to enable", comment: "Settings row value: needs permission")
                            )
                        }
                        NavigationLink {
                            NotificationsView()
                        } label: {
                            Text("Notification History")
                                .foregroundStyle(.white)
                        }
                    }
                } header: {
                    Text("Push Notifications")
                } footer: {
                    Text("Import the GoogleService-Info.plist from the Firebase project your ntfy server publishes through. NozzleCast will subscribe to the same alert topic Bambuddy already sends to.")
                }

                Section {
                    Button {
                        showConnectionSheet = true
                    } label: {
                        settingsRow(
                            title: String(localized: "Server", comment: "Settings row label"),
                            value: store.config.isConfigured
                                ? store.config.serverURLString
                                : String(localized: "Not configured", comment: "Settings row value when no server is set")
                        )
                    }
                    if store.config.isConfigured {
                        Button {
                            showConnectionSheet = true
                        } label: {
                            settingsRow(title: String(localized: "API Key", comment: "Settings row label"), value: store.config.maskedAPIKey)
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
                        Group {
                            if store.isRefreshing {
                                Text("Loading…")
                            } else {
                                Text("No printers found.")
                            }
                        }
                        .foregroundStyle(NCColor.textTertiary)
                    }
                    ForEach(store.printers) { printer in
                        NavigationLink(value: printer.id) {
                            HStack(spacing: 12) {
                                PrinterThumbnailImage(assetName: printer.imageAssetName)
                                    .frame(width: 30, height: 30)
                                    .padding(4)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(NCColor.printerWell))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(NCColor.printerWellBorder, lineWidth: 1))
                                Text(printer.name)
                                    .foregroundStyle(.white)
                                Spacer()
                                Text(printer.model)
                                    .foregroundStyle(NCColor.textTertiary)
                            }
                        }
                    }
                }

                Section("App Icon") {
                    ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(AppIconOption.allCases) { option in
                            Button {
                                selectIcon(option)
                            } label: {
                                VStack(spacing: 6) {
                                    Image(option.assetName)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 56, height: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .strokeBorder(selectedIcon == option ? NCColor.accent : Color.clear, lineWidth: 2.5)
                                        )
                                        .overlay(alignment: .bottomTrailing) {
                                            if selectedIcon == option {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .font(.system(size: 16))
                                                    .symbolRenderingMode(.palette)
                                                    .foregroundStyle(.white, NCColor.accent)
                                                    .offset(x: 4, y: 4)
                                            }
                                        }
                                    Text(option.title)
                                        .ncFont(size: 11, relativeTo: .caption2)
                                        .foregroundStyle(NCColor.textSecondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                    }
                }

                Section {
                    VStack(spacing: 8) {
                        Image("AppIconSource")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        Text("NozzleCast 1.0.0")
                            .ncFont(size: 13, weight: .semibold, relativeTo: .footnote)
                            .foregroundStyle(.white)
                        Text("Local-first control for your farm.")
                            .ncFont(size: 12, relativeTo: .caption)
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
            .refreshable { await store.testConnectionAndRefresh() }
            .sheet(isPresented: $showConnectionSheet) {
                BambuddyConnectionSheet()
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.propertyList, .xml, .item]) { result in
                switch result {
                case .success(let url):
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    do {
                        try FirebaseConfigStore.importConfig(from: url)
                        pushManager.configureFirebaseIfNeeded()
                    } catch {
                        importError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                case .failure(let error):
                    importError = error.localizedDescription
                }
            }
            .alert("Couldn't Import Config", isPresented: .init(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .task {
                await pushManager.refreshAuthorizationStatus()
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
                granted.append(String(localized: "Manage Inventory", comment: "Bambuddy API permission name"))
            }
            if store.grantedPermissions.contains("printers:read") {
                granted.append(String(localized: "Read Status", comment: "Bambuddy API permission name"))
            }
            if store.grantedPermissions.contains("printers:control") {
                granted.append(String(localized: "Printer Control", comment: "Bambuddy API permission name"))
            }
            if granted.isEmpty {
                return String(localized: "Connected.", comment: "Settings footer: connected with no listed permissions")
            }
            let list = ListFormatter.localizedString(byJoining: granted)
            return String(localized: "\(list) permissions granted.", comment: "Settings footer: list of granted API permissions")
        case .failed(let message):
            return String(localized: "Couldn't connect: \(message)", comment: "Settings footer: connection error")
        case .connecting:
            return String(localized: "Connecting to your Bambuddy server…", comment: "Settings footer: connecting")
        case .notConfigured:
            return String(localized: "Showing demo data. Tap Server to connect to your Bambuddy instance.", comment: "Settings footer: no server configured")
        }
    }

    private func selectIcon(_ option: AppIconOption) {
        guard option != selectedIcon else { return }
        UIApplication.shared.setAlternateIconName(option.alternateIconName) { error in
            guard error == nil else { return }
            Task { @MainActor in selectedIcon = option }
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
