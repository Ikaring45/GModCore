// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "GModCore",

    platforms: [
        .iOS("16.0")
    ],

    products: [
        .library(
            name: "GModApp",
            targets: ["GModApp"]
        )
    ],

    targets: [
        .target(
            name: "GModApp",
            path: "Sources/GModApp"
        )
    ]
)
