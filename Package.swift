// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClaudeView",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "ClaudeViewCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ClaudeView",
            dependencies: ["ClaudeViewCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ClaudeViewCoreTests",
            dependencies: ["ClaudeViewCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
