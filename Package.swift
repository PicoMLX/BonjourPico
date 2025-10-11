// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "BonjourPico",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "BonjourPico",
            targets: ["BonjourPico"])
    ],
    targets: [
        .target(
            name: "BonjourDiscoveryCore",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .unsafeFlags(["-warn-concurrency"])
            ]
        ),
        .target(
            name: "BonjourPico",
            dependencies: ["BonjourDiscoveryCore"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .unsafeFlags(["-warn-concurrency"])
            ]
        ),
        .testTarget(
            name: "BonjourPicoTests",
            dependencies: ["BonjourDiscoveryCore", "BonjourPico"]
        )
    ]
)
