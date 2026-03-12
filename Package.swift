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
    ],
    targets: [
        .executableTarget(
            name: "VoiceClutch",
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
