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
        ),
        .executable(
            name: "GModLuaConformance",
            targets: ["GModLuaConformance"]
        )
    ],

    targets: [
        .target(
            name: "GModLua",
            path: "Sources/GModLua"
        ),

        .target(
            name: "GModEngine",
            dependencies: [
                "GModLua"
            ],
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
        ),

        .executableTarget(
            name: "GModLuaConformance",
            dependencies: [
                "GModEngine"
            ],
            path: "Sources/GModLuaConformance",
            linkerSettings: [
                // The Windows default executable stack is too small for Lua
                // 5.1's required non-tail recursion depth. This affects only
                // the native diagnostic executable, not the iPad libraries.
                .unsafeFlags(
                    ["-Xlinker", "/STACK:16777216"],
                    .when(platforms: [.windows])
                )
            ]
        )
    ]
)
