// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "mipad2mac",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MiPad2Mac", targets: ["MiPad2Mac"])],
    targets: [
        .target(name: "MiPadCore"),
        .executableTarget(name: "MiPad2Mac", dependencies: ["MiPadCore"]),
        .testTarget(name: "MiPadCoreTests", dependencies: ["MiPadCore"])
    ]
)
