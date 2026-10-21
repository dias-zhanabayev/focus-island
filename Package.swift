// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OpenIsland",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "OpenIslandCore",
            targets: ["OpenIslandCore"]
        ),
        .library(name: "FocusCore", targets: ["FocusCore"]),
        .executable(
            name: "OpenIslandHooks",
            targets: ["OpenIslandHooks"]
        ),
        .executable(
            name: "OpenIslandSetup",
            targets: ["OpenIslandSetup"]
        ),
        .executable(
            name: "OpenIslandApp",
            targets: ["OpenIslandApp"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "OpenIslandCore"
        ),
        .target(
            name: "FocusCore",
            dependencies: [
                "OpenIslandCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "OpenIslandHooks",
            dependencies: ["OpenIslandCore"]
        ),
        .executableTarget(
            name: "OpenIslandSetup",
            dependencies: ["OpenIslandCore"]
        ),
        .executableTarget(
            name: "OpenIslandApp",
            dependencies: [
                "OpenIslandCore",
                "FocusCore",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "OpenIslandCoreTests",
            dependencies: ["OpenIslandCore"]
        ),
        .testTarget(
            name: "FocusCoreTests",
            dependencies: ["FocusCore", "OpenIslandCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "OpenIslandAppTests",
            dependencies: ["OpenIslandApp", "OpenIslandCore", "FocusCore"]
        ),
    ]
)
