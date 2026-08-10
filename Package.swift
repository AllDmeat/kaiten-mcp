// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "KaitenMCP",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    dependencies: [
        .package(
            url: "https://github.com/AllDmeat/KaitenSDK.git",
            from: "2.3.0"
        ),
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            from: "0.12.1"
        ),
    ],
    targets: [
        .executableTarget(
            name: "kaiten-mcp",
            dependencies: [
                .product(name: "KaitenSDK", package: "KaitenSDK"),
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "kaiten-mcpTests",
            dependencies: ["kaiten-mcp"]
        ),
    ]
)
