// swift-tools-version:6.0
import PackageDescription
import Foundation

// Absolute path to the package root, so the prebuilt AEC archive resolves regardless of the
// linker's working directory.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Jarvis",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "JarvisCore"),
        // The AppKit overlay lives in its own library target (not the executable) so it can be
        // imported by tests — see Tests/JarvisOverlayTests for the screen-capture invisibility checks.
        .target(name: "JarvisOverlay", dependencies: ["JarvisCore"]),
        // OS-bound private IPC plus the MCP stdio adapter. The action policy and validation stay in
        // JarvisCore; this target only carries calls between a local CLI child and that broker.
        .target(name: "JarvisMCPBridge", dependencies: ["JarvisCore"]),
        // Acoustic echo cancellation (WebRTC AEC3), the OS/native-bound edge. The C++ implementation
        // is prebuilt + statically merged with abseil into Sources/CJarvisAEC/lib/libjarvis-aec.a by scripts/build-aec.sh
        // (zero runtime dylib deps), so `swift build` compiles only the pure-C shim header and links
        // the archive — no C++ toolchain or vendored headers needed. See scripts/aec/jarvis_aec.cpp.
        .target(
            name: "CJarvisAEC",
            exclude: ["lib"],   // the prebuilt .a is linked, not compiled
            linkerSettings: [
                .unsafeFlags(["\(packageRoot)/Sources/CJarvisAEC/lib/libjarvis-aec.a"]),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("c++"),
            ]
        ),
        .executableTarget(
            name: "JarvisApp",
            dependencies: ["JarvisCore", "JarvisOverlay", "JarvisMCPBridge", "CJarvisAEC"]
        ),
        .executableTarget(
            name: "JarvisMCPServer",
            dependencies: ["JarvisMCPBridge"]
        ),
        // The dev-side CLI half of the agentic session audit (see AgenticEvaluation): renders a
        // session's traffic to a compact transcript and prints the agent task prompt. A separate,
        // Foundation-only executable so it builds/runs on any machine and scripts/eval-session.sh can
        // reuse Core's transcript rendering instead of reimplementing it in bash.
        .executableTarget(
            name: "EvalPrep",
            dependencies: ["JarvisCore"]
        ),
        .testTarget(
            name: "JarvisCoreTests",
            dependencies: ["JarvisCore"]
        ),
        .testTarget(
            name: "JarvisOverlayTests",
            dependencies: ["JarvisOverlay"]
        ),
        .testTarget(
            name: "JarvisMCPBridgeTests",
            dependencies: ["JarvisCore", "JarvisMCPBridge"]
        ),
        // WebKit-driven end-to-end tests for the activity viewer's shipped HTML/JS. Kept separate
        // from JarvisCoreTests so the core's own test target stays Foundation-only and the
        // "JarvisCore is UI-free" boundary holds literally. See wiki/build-and-run.md.
        .testTarget(
            name: "JarvisViewerTests",
            dependencies: ["JarvisCore"]
        ),
    ]
)
