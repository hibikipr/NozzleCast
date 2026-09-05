import SwiftUI

@main
struct MyApp: App {
    // `appDelegate.store` (not a separate `@State` here) so the same `AppStore` instance the
    // AppDelegate created before this Scene existed is the one the UI reads from — see
    // `AppDelegate.store`'s doc comment for why a second, independently-created instance here
    // would leave a headless-background-launched store unreachable from the UI, and vice versa.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appDelegate.store)
        }
    }
}
