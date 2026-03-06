// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsage",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClaudeUsage", targets: ["ClaudeUsage"]),
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.5.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "ClaudeUsage",
            dependencies: [
                "TOMLKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/ClaudeUsage",
            exclude: ["Resources/Info.plist"],
            resources: [
                .process("Resources"),
                .copy("Scriptable/ClaudeUsage.sdef"),
            ]
        ),
        .testTarget(
            name: "ClaudeUsageTests",
            dependencies: [
                "ClaudeUsage",
                "TOMLKit",
            ],
            path: "Tests/ClaudeUsageTests"
        ),
    ]
)
