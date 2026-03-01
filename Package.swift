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
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "ClaudeUsageCore",
            path: "Sources/ClaudeUsageCore"
        ),
        .executableTarget(
            name: "ClaudeUsage",
            dependencies: [
                "ClaudeUsageCore",
                "TOMLKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/ClaudeUsage",
            exclude: ["Resources/Info.plist"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "ClaudeUsageCLI",
            dependencies: ["ClaudeUsageCore", "TOMLKit"],
            path: "Sources/ClaudeUsageCLI"
        ),
        .testTarget(
            name: "ClaudeUsageTests",
            dependencies: [
                "ClaudeUsage",
                "ClaudeUsageCore",
                "TOMLKit",
            ],
            path: "Tests/ClaudeUsageTests"
        ),
    ]
)
