// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TicTracker",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "TicTracker",
            path: "Sources"
        )
    ]
)
