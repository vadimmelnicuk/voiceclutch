// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "VoiceClutch",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(
            name: "VoiceClutch",
            targets: ["VoiceClutch"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm",
            .upToNextMinor(from: "2.30.6")
        ),
    ],
    targets: [
        .executableTarget(
            name: "VoiceClutch",
            dependencies: [
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
            ],
            path: "Sources/VoiceClutch",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreML"),
            ]
        ),
    ]
)
