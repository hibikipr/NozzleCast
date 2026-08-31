import SwiftUI

@main
struct MyApp: App {
    @State private var store = AppStore(config: BambuddyConfig())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
        }
    }
}
