// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HiDockKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HiDockKit", targets: ["HiDockKit"]),
        .executable(name: "hidock-cli", targets: ["HiDockCLI"]),
        .library(name: "HiDockMenubar", targets: ["HiDockMenubar"]),
        .executable(name: "HiDockApp", targets: ["HiDockApp"]),
    ],
    targets: [
        .target(name: "HiDockKit"),
        .executableTarget(name: "HiDockCLI", dependencies: ["HiDockKit", "HiDockMenubar"]),
        .testTarget(name: "HiDockKitTests", dependencies: ["HiDockKit"]),
        // A LIBRARY, not an executable. All app logic and views live here so the
        // test target can @testable import it. Task 10 adds a thin `HiDockApp`
        // executable target carrying only @main and Info.plist. Declaring this
        // executable now would fail to link (no main entry point yet) and would
        // make the test target depend on an executable, which SPM handles
        // awkwardly.
        .target(
            name: "HiDockMenubar",
            dependencies: ["HiDockKit"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "HiDockMenubarTests", dependencies: ["HiDockMenubar", "HiDockKit"]),
        // Thin shell: @main plus the bundle plist. All logic and views live in
        // HiDockMenubar (see the comment above) so they stay testable. The
        // plist is copied into the .app bundle by Scripts/make-app.sh, not
        // processed by SPM, hence the exclude.
        .executableTarget(
            name: "HiDockApp",
            dependencies: ["HiDockMenubar", "HiDockKit"],
            exclude: ["Info.plist"]
        ),
    ]
)
