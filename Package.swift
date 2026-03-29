// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SageBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SageBar", targets: ["SageBar"]),
        .executable(name: "SageBarWidget", targets: ["SageBarWidget"]),
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.5.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "SageBar",
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
        .executableTarget(
            name: "SageBarWidget",
            path: "Sources/SageBarWidget",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "SageBarTests",
            dependencies: [
                "SageBar",
                "TOMLKit",
            ],
            path: "Tests/ClaudeUsageTests"
        ),
    ]
)
