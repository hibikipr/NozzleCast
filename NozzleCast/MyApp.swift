import SwiftUI

@main
struct MyApp: App {
    @State private var store = MockData.makeStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
        }
    }
}
