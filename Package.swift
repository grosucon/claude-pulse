// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudePulse",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClaudePulseCore", targets: ["ClaudePulseCore"]),
    ],
    targets: [
        .target(
            name: "ClaudePulseCore",
            path: "Sources/ClaudePulseCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "CPSmoke",
            dependencies: ["ClaudePulseCore"],
            path: "Sources/CPSmoke",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ClaudePulse",
            dependencies: ["ClaudePulseCore"],
            path: "Sources/ClaudePulse",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ClaudePulseCoreTests",
            dependencies: ["ClaudePulseCore"],
            path: "Tests/ClaudePulseCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
