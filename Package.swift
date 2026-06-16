// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Jarvis",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "JarvisCore"),
        // The AppKit overlay lives in its own library target (not the executable) so it can be
        // imported by tests — see Tests/JarvisOverlayTests for the screen-capture invisibility checks.
        .target(name: "JarvisOverlay", dependencies: ["JarvisCore"]),
        .executableTarget(
            name: "JarvisApp",
            dependencies: ["JarvisCore", "JarvisOverlay"]
        ),
        .testTarget(
            name: "JarvisCoreTests",
            dependencies: ["JarvisCore"]
        ),
        .testTarget(
            name: "JarvisOverlayTests",
            dependencies: ["JarvisOverlay"]
        ),
    ]
)
