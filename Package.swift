// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsage",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClaudeUsage", targets: ["ClaudeUsage"]),
        .executable(name: "claude-usage", targets: ["ClaudeUsageCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.5.0"),
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern", from: "1.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "ClaudeUsage",
            dependencies: [
                "TOMLKit",
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/ClaudeUsage",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "ClaudeUsageCLI",
            dependencies: ["TOMLKit"],
            path: "Sources/ClaudeUsageCLI"
        ),
        .testTarget(
            name: "ClaudeUsageTests",
            dependencies: [
                "TOMLKit",
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Tests/ClaudeUsageTests",
            sources: ["."]
        ),
    ]
)
