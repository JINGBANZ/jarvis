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
        .testTarget(
            name: "JarvisCoreTests",
            dependencies: ["JarvisCore"]
        ),
        // WebKit-driven end-to-end tests for the activity viewer's shipped HTML/JS. Kept separate
        // from JarvisCoreTests so the core's own test target stays Foundation-only and the
        // "JarvisCore is UI-free" boundary holds literally. See wiki/activity-viewer.md.
        .testTarget(
            name: "JarvisViewerTests",
            dependencies: ["JarvisCore"]
        ),
    ]
)
