// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HiDockKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HiDockKit", targets: ["HiDockKit"]),
        .executable(name: "hidock-cli", targets: ["HiDockCLI"]),
    ],
    targets: [
        .target(name: "HiDockKit"),
        .executableTarget(name: "HiDockCLI", dependencies: ["HiDockKit"]),
        .testTarget(name: "HiDockKitTests", dependencies: ["HiDockKit"]),
    ]
)
