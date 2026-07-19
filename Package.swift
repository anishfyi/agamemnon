// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Warden",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Warden", targets: ["Warden"]),
        .executable(name: "WardenTests", targets: ["WardenTests"]),
        .library(name: "WardenCore", targets: ["WardenCore"]),
    ],
    targets: [
        .target(
            name: "WardenCore",
            path: "Sources/WardenCore"
        ),
        .executableTarget(
            name: "Warden",
            dependencies: ["WardenCore"],
            path: "Sources/Warden"
        ),
        // Standalone test runner (works with Command Line Tools; no XCTest / full Xcode required).
        // Fixtures live under Tests/WardenTests/Fixtures.
        .executableTarget(
            name: "WardenTests",
            dependencies: ["WardenCore"],
            path: "Tests/WardenTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
