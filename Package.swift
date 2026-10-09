// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "agentwatch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "agentwatch", path: "Sources/agentwatch", sources: ["Analytics.swift", "LegacyMetrics.swift", "Dashboard.swift"]),
        .testTarget(name: "AgentWatchTests", dependencies: ["agentwatch"], path: "Tests/AgentWatchTests")
    ]
)
