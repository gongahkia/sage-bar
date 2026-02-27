// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsage",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClaudeUsage", targets: ["ClaudeUsage"]),
        .executable(name: "claude-usage", targets: ["ClaudeUsageCLI"]),
    ],
    targets: [
        .executableTarget(
            name: "ClaudeUsage",
            path: "Sources/ClaudeUsage",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "ClaudeUsageCLI",
            path: "Sources/ClaudeUsageCLI"
        ),
    ]
)
