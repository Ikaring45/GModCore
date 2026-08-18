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
        .binaryTarget(
            name: "GModCoreBinary",
            path: "Binaries/GModCore.xcframework"
        ),

        .target(
            name: "GModApp",
            dependencies: ["GModCoreBinary"],
            path: "Sources/GModApp"
        )
    ]
)
