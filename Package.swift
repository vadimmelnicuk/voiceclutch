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
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "fdf6e4c71137a3831d8b732d36102a0a8d5105e3"
        ),
    ],
    targets: [
        .executableTarget(
            name: "VoiceClutch",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/VoiceClutch",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreML"),
            ]
        )
    ]
)
