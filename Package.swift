// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Steno",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "JensenKit", targets: ["JensenKit"]),
        .executable(name: "steno", targets: ["StenoCLI"]),
        .library(name: "StenoUI", targets: ["StenoUI"]),
        .executable(name: "StenoApp", targets: ["StenoApp"]),
    ],
    targets: [
        // The wire protocol, named after the protocol itself rather than the
        // vendor whose hardware speaks it: every type in here is a `Jensen`
        // one, and the module is a clean-room implementation, not the
        // vendor's own.
        .target(name: "JensenKit"),
        .executableTarget(name: "StenoCLI", dependencies: ["JensenKit", "StenoUI"]),
        .testTarget(name: "JensenKitTests", dependencies: ["JensenKit"]),
        // A LIBRARY, not an executable. All app logic and views live here so the
        // test target can @testable import it. The thin `StenoApp` executable
        // target below carries only @main and Info.plist. Declaring this
        // executable would make the test target depend on an executable, which
        // SPM handles awkwardly.
        .target(
            name: "StenoUI",
            dependencies: ["JensenKit"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "StenoUITests", dependencies: ["StenoUI", "JensenKit"]),
        // Thin shell: @main plus the bundle plist. All logic and views live in
        // StenoUI (see the comment above) so they stay testable. The plist is
        // copied into the .app bundle by Scripts/make-app.sh, not processed by
        // SPM, hence the exclude.
        .executableTarget(
            name: "StenoApp",
            dependencies: ["StenoUI", "JensenKit"],
            exclude: ["Info.plist"]
        ),
    ]
)
