// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LetItBrew",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LetItBrewAppCore", dependencies: ["LetItBrewCore"]),
        .target(name: "LetItBrewCore"),
        .target(name: "LetItBrewDaemonCore", dependencies: ["LetItBrewCore"]),
        .executableTarget(name: "letitbrew", dependencies: ["LetItBrewCore"]),
        .testTarget(
            name: "LetItBrewAppCoreTests",
            dependencies: ["LetItBrewAppCore"]
        ),
        .testTarget(name: "LetItBrewCoreTests", dependencies: ["LetItBrewCore"]),
        .testTarget(
            name: "LetItBrewIntegrationTests",
            dependencies: ["LetItBrewCore", "LetItBrewAppCore"]
        ),
        .testTarget(
            name: "LetItBrewDaemonCoreTests",
            dependencies: ["LetItBrewDaemonCore"]
        ),
    ]
)
