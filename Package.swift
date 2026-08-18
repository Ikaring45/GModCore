// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "GModCore",

    products: [
        .library(
            name: "GModCore",
            targets: ["GModCore"]
        )
    ],

    targets: [
        .target(
            name: "GModCore",
            path: "Sources/GModCore",
            publicHeadersPath: "include"
        )
    ],

    cxxLanguageStandard: .cxx17
)
