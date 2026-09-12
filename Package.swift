// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Vela", platforms: [.macOS(.v13)],
    products: [.library(name: "VelaCore", targets: ["VelaCore"]), .executable(name: "vela", targets: ["VelaCLI"]), .executable(name: "VelaDesktop", targets: ["VelaApp"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "VelaCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "VelaCLI", dependencies: ["VelaCore"]),
        .executableTarget(name: "VelaApp", resources: [.copy("Resources")]),
        .testTarget(name: "VelaCoreTests", dependencies: ["VelaCore"])
    ]
)
