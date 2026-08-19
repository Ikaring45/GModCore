// swift-tools-version: 5.9

import PackageDescription

var products: [Product] = [
    .executable(
        name: "GModLuaConformance",
        targets: ["GModLuaConformance"]
    )
]

var targets: [Target] = [
    .target(
        name: "GModImageDecode",
        path: "Sources/GModImageDecode",
        publicHeadersPath: "include",
        linkerSettings: [
            .linkedLibrary("ole32", .when(platforms: [.windows])),
            .linkedLibrary("windowscodecs", .when(platforms: [.windows])),
            .linkedFramework("CoreFoundation", .when(platforms: [.iOS, .macOS])),
            .linkedFramework("CoreGraphics", .when(platforms: [.iOS, .macOS])),
            .linkedFramework("ImageIO", .when(platforms: [.iOS, .macOS]))
        ]
    ),

    .target(
        name: "GModLua",
        path: "Sources/GModLua"
    ),

    .target(
        name: "GModEngine",
        dependencies: [
            "GModLua",
            "GModImageDecode"
        ],
        path: "Sources/GModEngine",
        linkerSettings: [
            // Windows ships SQLite as winsqlite3 while Apple platforms and
            // Linux expose the same C ABI from sqlite3.
            .linkedLibrary("winsqlite3", .when(platforms: [.windows])),
            .linkedLibrary("sqlite3", .when(platforms: [.iOS, .macOS, .linux]))
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
    ),

    .testTarget(
        name: "GModEngineTests",
        dependencies: [
            "GModEngine",
            "GModLua"
        ],
        path: "Tests/GModEngineTests",
        resources: [
            .copy("Fixtures")
        ]
    )
]

#if !os(Windows) && !os(Linux)
// Metal and the SwiftUI application are Apple-only. Keeping them out of the
// non-Apple manifest graph lets the native conformance runner and XCTest suite
// build without requiring unavailable Apple frameworks.
products.insert(
    .library(
        name: "GModApp",
        targets: ["GModApp"]
    ),
    at: 0
)

targets.insert(
    contentsOf: [
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
    ],
    at: 2
)
#endif

let package = Package(
    name: "GModCore",

    platforms: [
        .iOS(.v16)
    ],

    products: products,

    targets: targets
)
