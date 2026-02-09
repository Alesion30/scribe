// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "scribe",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "scribe",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "WhisperCpp",
            ],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .binaryTarget(
            name: "WhisperCpp",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.8.3/whisper-v1.8.3-xcframework.zip",
            checksum: "a970006f256c8e689bc79e73f7fa7ddb8c1ed2703ad43ee48eb545b5bb6de6af"
        ),
    ]
)
