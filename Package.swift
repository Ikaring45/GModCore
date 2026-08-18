// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "GModCore",

    platforms: [
        .iOS(.v16)
    ],

    products: [
        .library(
            name: "GModApp",
            targets: ["GModApp"]
        )
    ],

    targets: [
        .target(
            name: "GModEngine",
            path: "Sources/GModEngine"
        ),

        .target(
            name: "GModMetal",
            dependencies: [
                "GModEngine"
            ],
            path: "Sources/GModMetal"
        ),

        .target(
            name: "GModApp",
            dependencies: [
                "GModEngine",
                "GModMetal"
            ],
            path: "Sources/GModApp",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
