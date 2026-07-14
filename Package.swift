// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PalmierPro",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "PalmierPro", targets: ["PalmierPro"]),
    ],
    traits: [
        .trait(name: "BundledSpeech", description: "Include on-device speech models and MLX."),
        .trait(name: "ProductionTelemetry", description: "Include Sentry and PostHog telemetry."),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", exact: "9.21.0"),
        .package(url: "https://github.com/PostHog/posthog-ios.git", exact: "3.64.4"),
        .package(url: "https://github.com/clerk/clerk-convex-swift", from: "0.1.0"),
        .package(url: "https://github.com/clerk/clerk-ios", from: "1.2.1"),
        .package(url: "https://github.com/get-convex/convex-swift", from: "0.8.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.5"),
        .package(url: "https://github.com/airbnb/lottie-ios", from: "4.6.1"),
        .package(url: "https://github.com/soniqo/speech-swift", exact: "0.0.21"),
    ],
    targets: [
        .executableTarget(
            name: "PalmierPro",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(
                    name: "Sentry",
                    package: "sentry-cocoa",
                    condition: .when(traits: ["ProductionTelemetry"])
                ),
                .product(
                    name: "PostHog",
                    package: "posthog-ios",
                    condition: .when(traits: ["ProductionTelemetry"])
                ),
                .product(name: "ClerkConvex", package: "clerk-convex-swift"),
                .product(name: "ClerkKit", package: "clerk-ios"),
                .product(name: "ConvexMobile", package: "convex-swift"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Lottie", package: "lottie-ios"),
                .product(
                    name: "MLX",
                    package: "mlx-swift",
                    condition: .when(traits: ["BundledSpeech"])
                ),
                .product(
                    name: "SpeechEnhancement",
                    package: "speech-swift",
                    condition: .when(traits: ["BundledSpeech"])
                ),
                .product(
                    name: "SpeechVAD",
                    package: "speech-swift",
                    condition: .when(traits: ["BundledSpeech"])
                ),
            ],
            path: "Sources/PalmierPro",
            exclude: [
                "Resources/Info.plist",
                "Resources/AppIcon.icon",
                "Resources/AppIcon.icns",
                "Resources/AppIcon.png",
            ],
            resources: [
                .copy("Resources/Fonts"),
                .copy("Resources/MCPB/palmier-pro.mcpb"),
                .copy("Resources/Images"),
                .copy("Resources/Changelog"),
                .copy("Resources/Localization"),
                .copy("Resources/Models"),
            ],
            swiftSettings: [
                .define("BUNDLED_SPEECH", .when(traits: ["BundledSpeech"])),
                .define("PRODUCTION_TELEMETRY", .when(traits: ["ProductionTelemetry"])),
            ],
            plugins: ["MetalCIKernelPlugin"]
        ),
        .plugin(name: "MetalCIKernelPlugin", capability: .buildTool()),
        .testTarget(
            name: "PalmierProTests",
            dependencies: ["PalmierPro"],
            path: "Tests/PalmierProTests"
        ),
    ]
)
