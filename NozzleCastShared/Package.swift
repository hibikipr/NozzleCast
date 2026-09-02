// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NozzleCastShared",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "NozzleCastShared", targets: ["NozzleCastShared"]),
    ],
    targets: [
        .target(name: "NozzleCastShared"),
    ]
)
