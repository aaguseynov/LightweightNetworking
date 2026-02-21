// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LightweightNetworking",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "LightweightNetworking",
            type: .static,
            targets: ["LightweightNetworking"]
        )
    ],
    targets: [
        .target(
            name: "LightweightNetworking",
            path: "Sources/LightweightNetworking",
            swiftSettings: [
                .enableExperimentalFeature("AccessLevelOnImport")
            ]
        )
    ]
)
