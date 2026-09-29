import SwiftUI

enum RootTab: Hashable {
    case monitor, inventory, scan, settings
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var selectedTab: RootTab = .monitor

    var body: some View {
        TabView(selection: $selectedTab) {
            MonitorView(selectedTab: $selectedTab)
                .tabItem { Label("Monitor", systemImage: "square.grid.2x2") }
                .tag(RootTab.monitor)

            InventoryView(selectedTab: $selectedTab)
                .tabItem { Label("Inventory", systemImage: "circle.grid.cross") }
                .tag(RootTab.inventory)

            ScanView(selectedTab: $selectedTab)
                .tabItem { Label("Scan", systemImage: "camera.viewfinder") }
                .tag(RootTab.scan)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(RootTab.settings)
        }
        .tint(NCColor.accent)
        .preferredColorScheme(.dark)
        // Tapping the Live Activity can land here from any tab — jump to Monitor first;
        // `MonitorView` itself pushes to the specific printer once its printer list is loaded.
        .onChange(of: store.pendingDeepLinkPrinterID) { _, id in
            if id != nil { selectedTab = .monitor }
        }
        .alert(
            Text("Couldn't Complete That", comment: "Alert title when a printer/inventory action fails"),
            isPresented: Binding(
                get: { store.actionError != nil },
                set: { if !$0 { store.actionError = nil } }
            ),
            presenting: store.actionError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }
}

#Preview {
    RootView()
        .environment(AppStore(config: BambuddyConfig()))
}
