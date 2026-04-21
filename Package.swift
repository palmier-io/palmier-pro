// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PalmierPro",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "PalmierPro", targets: ["PalmierPro"]),
    ],
    dependencies: [
        .package(url: "https://github.com/fal-ai/fal-swift", from: "0.5.6"),
        .package(url: "https://github.com/dmrschmidt/DSWaveformImage", from: "14.2.2"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "PalmierPro",
            dependencies: [
                .product(name: "FalClient", package: "fal-swift"),
                .product(name: "DSWaveformImage", package: "DSWaveformImage"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/PalmierPro",
            exclude: [
                "Resources/Info.plist",
                "Resources/AppIcon.icon",
                "Resources/AppIcon.icns",
                "Resources/AppIcon.png",
            ]
        ),
    ]
)
