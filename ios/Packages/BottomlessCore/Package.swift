// swift-tools-version:5.9
import PackageDescription

// Everything the app does that is not UI or PhotoKit: API client, local catalog (SQLite), sync, cache policy,
// backup pipeline, hashing and thumbnail/preview generation. Builds and tests on macOS too.
let package = Package(
    name: "BottomlessCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "BottomlessCore", targets: ["BottomlessCore"]),
        .executable(name: "bottomless-import", targets: ["bottomless-import"]),
    ],
    targets: [
        .target(name: "BottomlessCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "bottomless-import", dependencies: ["BottomlessCore"]),
        .testTarget(name: "BottomlessCoreTests", dependencies: ["BottomlessCore"]),
    ]
)
