// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "GModCore",

    platforms: [
        .iOS(.v16)
    ],

    products: [
        .library(
            name: "GModCoreBinary",
            targets: ["GModCoreBinary"]
        )
    ],

    targets: [
        .binaryTarget(
            name: "GModCoreBinary",
            path: "Binaries/GModCore.xcframework"
        )
    ]
)
