// swift-tools-version:6.0
import PackageDescription
import Foundation

// Absolute path to the package root, so the prebuilt AEC archive resolves regardless of the
// linker's working directory.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

// Source files decide whether the macOS 26 Apple Speech APIs exist by checking the active SDK at
// their compile site. The package manifest cannot make that decision: SwiftPM compiles it against
// the host SDK even when `swift build --sdk ...` selects a different target SDK.
//
// Set `JARVIS_FORCE_APPLE_SPEECH_FALLBACK=1` to compile the fallback on a macOS 26 SDK so that path
// remains independently buildable. Use a clean scratch path when switching the flag because SwiftPM
// does not treat environment-only manifest changes as source changes.
let forceAppleSpeechFallback =
    ProcessInfo.processInfo.environment["JARVIS_FORCE_APPLE_SPEECH_FALLBACK"] == "1"
let jarvisAppSwiftSettings: [SwiftSetting] = forceAppleSpeechFallback
    ? [.define("JARVIS_FORCE_APPLE_SPEECH_FALLBACK")]
    : []

let package = Package(
    name: "Jarvis",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "JarvisCore"),
        // The AppKit overlay lives in its own library target (not the executable) so it can be
        // imported by tests — see Tests/JarvisOverlayTests for the screen-capture invisibility checks.
        .target(name: "JarvisOverlay", dependencies: ["JarvisCore"]),
        // WebRTC audio processing (AEC3 + classic VAD), the OS/native-bound edge. The C++ AEC3
        // implementation and upstream VAD are prebuilt + statically merged with abseil into
        // Sources/CJarvisAEC/lib/libjarvis-aec.a by scripts/build-aec.sh (zero runtime dylib deps),
        // so `swift build` compiles only the dependency-free C facade and links the archive — no C++
        // toolchain or vendored headers needed. See scripts/aec/jarvis_aec.cpp.
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
            dependencies: ["JarvisCore", "JarvisOverlay", "CJarvisAEC"],
            swiftSettings: jarvisAppSwiftSettings
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
        // WebKit-driven end-to-end tests for the activity viewer's shipped HTML/JS. Kept separate
        // from JarvisCoreTests so the core's own test target stays Foundation-only and the
        // "JarvisCore is UI-free" boundary holds literally. See wiki/build-and-run.md.
        .testTarget(
            name: "JarvisViewerTests",
            dependencies: ["JarvisCore"]
        ),
    ]
)
