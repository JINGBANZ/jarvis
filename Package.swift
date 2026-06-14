// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Jarvis",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "JarvisCore"),
        .executableTarget(
            name: "JarvisApp",
            dependencies: ["JarvisCore"]
        ),
        // Headless integration probe: verifies the live Realtime transcription handshake using the
        // same RealtimeSession contract as the app. No GUI / mic / TCC needed — just an API key.
        .executableTarget(
            name: "RealtimeProbe",
            dependencies: ["JarvisCore"]
        ),
        .testTarget(
            name: "JarvisCoreTests",
            dependencies: ["JarvisCore"]
        ),
    ]
)
