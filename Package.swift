// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "BonjourPico",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "BonjourPico",
            targets: ["BonjourPico"]),
    ],
    targets: [
        .target(name: "BonjourPico"),
    ]
)
