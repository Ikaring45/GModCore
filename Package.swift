// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "GModCore",

    products: [
        .library(
            name: "GModCore",
            targets: ["GModCore"]
        ),
        .library(
            name: "GModApp",
            targets: ["GModApp"]
        )
    ],

    targets: [
        .target(
            name: "GModCore",
            path: "Sources/GModCore",
            publicHeadersPath: "include"
        ),

        .target(
            name: "GModApp",
            dependencies: ["GModCore"],
            path: "Sources/GModApp"
        )
    ],

    cxxLanguageStandard: .cxx17
)
