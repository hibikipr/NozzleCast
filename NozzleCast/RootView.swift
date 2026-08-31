import SwiftUI

enum RootTab: Hashable {
    case monitor, inventory, scan, settings
}

struct RootView: View {
    @State private var selectedTab: RootTab = .monitor

    var body: some View {
        TabView(selection: $selectedTab) {
            MonitorView()
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
    }
}

#Preview {
    RootView()
        .environment(MockData.makeStore())
}
