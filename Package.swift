// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PalmierPro",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PalmierPro", targets: ["PalmierPro"]),
    ],
    dependencies: [
        .package(url: "https://github.com/fal-ai/fal-swift", from: "0.5.6"),
        .package(url: "https://github.com/dmrschmidt/DSWaveformImage", from: "14.2.2"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
    ],
    targets: [
        .executableTarget(
            name: "PalmierPro",
            dependencies: [
                .product(name: "FalClient", package: "fal-swift"),
                .product(name: "DSWaveformImage", package: "DSWaveformImage"),
            ],
            path: "Sources/PalmierPro",
            exclude: ["Resources/Info.plist"]
        ),
        .testTarget(
            name: "PalmierProTests",
            dependencies: [
                "PalmierPro",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            path: "Tests/PalmierProTests"
        ),
    ]
)
