// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Agamemnon",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Agamemnon", targets: ["Agamemnon"]),
        .executable(name: "AgamemnonTests", targets: ["AgamemnonTests"]),
        .library(name: "AgamemnonCore", targets: ["AgamemnonCore"]),
    ],
    targets: [
        .target(
            name: "AgamemnonCore",
            path: "Sources/AgamemnonCore"
        ),
        .executableTarget(
            name: "Agamemnon",
            dependencies: ["AgamemnonCore"],
            path: "Sources/Agamemnon",
            resources: [
                .process("Resources"),
            ]
        ),
        // Standalone test runner (works with Command Line Tools; no XCTest / full Xcode required).
        // Fixtures live under Tests/AgamemnonTests/Fixtures.
        .executableTarget(
            name: "AgamemnonTests",
            dependencies: ["AgamemnonCore"],
            path: "Tests/AgamemnonTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
