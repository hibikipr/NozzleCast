import SwiftUI

@main
struct MyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore(config: BambuddyConfig())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
        }
    }
}
