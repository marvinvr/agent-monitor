// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentMonitor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AgentMonitor",
            path: "Sources"
        )
    ]
)
