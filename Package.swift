// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TicTracker",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TicTracker",
            path: "Sources",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .unsafeFlags(["-warnings-as-errors"]),
            ]
        )
    ]
)
