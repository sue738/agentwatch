// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "agentwatch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "agentwatch", path: "Sources/agentwatch", sources: ["AgstatsScanner.swift", "Analytics.swift", "LegacyMetrics.swift", "Dashboard.swift", "SampleData.swift", "LiveState.swift"]),
        .testTarget(name: "AgentWatchTests", dependencies: ["agentwatch"], path: "Tests/AgentWatchTests")
    ]
)
