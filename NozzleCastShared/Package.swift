// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NozzleCastShared",
    // macOS is declared only so `swift test` can build this package on a Mac for
    // ActivityTeardownPolicy's tests -- nothing here ships to macOS. Without it SwiftUI symbols
    // resolve against the 10.13 default and every view in FilamentSwatchView fails availability.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        // Both targets ship in the one product the app already links, so
        // ActivityTeardownPolicy is importable app-side with no Xcode project change.
        .library(name: "NozzleCastShared", targets: ["NozzleCastShared", "ActivityTeardownPolicy"]),
    ],
    targets: [
        .target(name: "NozzleCastShared", dependencies: ["ActivityTeardownPolicy"]),
        // Deliberately free of ActivityKit/SwiftUI so it (and its tests) build on macOS under
        // plain `swift test` -- NozzleCastShared itself cannot, ActivityAttributes is iOS-only.
        .target(name: "ActivityTeardownPolicy"),
        .testTarget(name: "ActivityTeardownPolicyTests", dependencies: ["ActivityTeardownPolicy"]),
    ]
)
