// swift-tools-version: 5.9

import PackageDescription

var products: [Product] = [
    .executable(
        name: "GModLuaConformance",
        targets: ["GModLuaConformance"]
    )
]

var engineDependencies: [Target.Dependency] = ["GModLua"]
var platformImageDecodeTargets: [Target] = []

#if os(Windows) || os(Linux)
engineDependencies.append("GModImageDecode")
platformImageDecodeTargets.append(
    .target(
        name: "GModImageDecode",
        path: "Sources/GModImageDecode",
        publicHeadersPath: "include",
        linkerSettings: [
            .linkedLibrary("ole32", .when(platforms: [.windows])),
            .linkedLibrary("windowscodecs", .when(platforms: [.windows]))
        ]
    )
)
#endif

var targets: [Target] = platformImageDecodeTargets + [
    .target(
        name: "GModGameAssets",
        path: "Sources/GModGameAssets",
        resources: [
            .copy("Resources/ClientContent"),
            .copy("Resources/Maps"),
            .copy("Resources/GModClientContentManifest.json"),
            .copy("Resources/GModGameAssetManifest.json"),
            .copy("Resources/GModSourceMaterialAllowlist.json")
        ]
    ),

    .target(
        name: "GModLua",
        path: "Sources/GModLua"
    ),

    .target(
        name: "GModEngine",
        dependencies: engineDependencies,
        path: "Sources/GModEngine",
        resources: [
            .copy("Resources/Lua51Tests")
        ],
        linkerSettings: [
            // Windows ships SQLite as winsqlite3 while Apple platforms and
            // Linux expose the same C ABI from sqlite3.
            .linkedLibrary("winsqlite3", .when(platforms: [.windows])),
            .linkedLibrary("sqlite3", .when(platforms: [.iOS, .macOS, .linux])),
            .linkedFramework("CoreFoundation", .when(platforms: [.iOS, .macOS])),
            .linkedFramework("CoreGraphics", .when(platforms: [.iOS, .macOS])),
            .linkedFramework("ImageIO", .when(platforms: [.iOS, .macOS]))
        ]
    ),

    .target(
        name: "GModGameSession",
        dependencies: [
            "GModEngine",
            "GModGameAssets",
            "GModLua"
        ],
        path: "Sources/GModGameSession"
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
            "GModLua",
            "GModGameAssets",
            "GModGameSession"
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
            path: "Sources/GModMetal",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText")
            ]
        ),

        .target(
            name: "GModApp",
            dependencies: [
                "GModEngine",
                "GModLua",
                "GModMetal",
                "GModGameAssets",
                "GModGameSession"
            ],
            path: "Sources/GModApp",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText")
            ]
        ),

        .testTarget(
            name: "GModAppTests",
            dependencies: [
                "GModApp",
                "GModEngine",
                "GModLua",
                "GModMetal"
            ],
            path: "Tests/GModAppTests"
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
