// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "mipad2mac",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MiPad2Mac", targets: ["MiPad2Mac"]),
               .executable(name: "MiPad2MacUpdater", targets: ["MiPad2MacUpdater"])],
    targets: [
        .target(name: "MiPadCore"),
        .target(name: "MiPadUpdateCore", dependencies: ["MiPadCore"]),
        .target(name: "MiPadUpdateTransport", dependencies: ["MiPadUpdateCore"]),
        .executableTarget(name: "MiPad2Mac", dependencies: ["MiPadCore", "MiPadUpdateCore", "MiPadUpdateTransport"]),
        .executableTarget(name: "MiPad2MacUpdater", dependencies: ["MiPadUpdateCore"]),
        .testTarget(name: "MiPadUpdateCoreTests", dependencies: ["MiPadUpdateCore", "MiPadUpdateTransport"]),
        .testTarget(name: "MiPadCoreTests", dependencies: ["MiPadCore"])
    ]
)
