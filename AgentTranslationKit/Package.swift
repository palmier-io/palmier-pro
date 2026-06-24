// swift-tools-version: 5.9

import PackageDescription

// Standalone, Foundation-only package holding the OpenAI/Anthropic message
// translation + SSE decode logic. No Apple-platform restriction and no AppKit,
// so it builds and tests on Linux / Windows / macOS with `swift test`.
// The macOS app depends on this package so there is a single source of truth.
let package = Package(
    name: "AgentTranslationKit",
    products: [
        .library(name: "AgentTranslation", targets: ["AgentTranslation"]),
    ],
    targets: [
        .target(name: "AgentTranslation"),
        .testTarget(name: "AgentTranslationTests", dependencies: ["AgentTranslation"]),
    ]
)
