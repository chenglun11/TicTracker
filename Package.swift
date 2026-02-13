// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TicTracker",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TicTracker",
            path: "Sources"
        )
    ]
)
