// swift-tools-version:6.0
import PackageDescription
import Foundation

// Absolute path to the package root, so the prebuilt AEC archive resolves regardless of the
// linker's working directory.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

// Single source of truth for whether the active toolchain ships the macOS 26 `SpeechAnalyzer` /
// `SpeechTranscriber` APIs that back Apple Speech transcription. `@available(macOS 26.0, *)` gates
// *runtime* execution, but it does not hide those type names from an older SDK/compiler, so every
// direct reference needs a *compile-time* boundary. Xcode 26 is the first SDK to contain the
// symbols and it pairs with Swift 6.2, so the compiler version is the compile-time proxy for SDK
// availability; older toolchains (e.g. the macOS 15 CI runner on Swift 6.1.x) build the fallback
// that reports Apple Speech unavailable. The manifest is compiled by the same toolchain that builds
// the package, so `#if compiler(...)` here reflects the real build compiler.
//
// Set `JARVIS_FORCE_APPLE_SPEECH_FALLBACK=1` to force-build the fallback path on a new toolchain so
// it can't silently bit-rot; run it from a clean checkout (CI) or after `rm -rf .build`, since SPM
// does not treat an env-var change alone as a reason to reconfigure.
var jarvisAppSwiftSettings: [SwiftSetting] = []
#if compiler(>=6.2)
if ProcessInfo.processInfo.environment["JARVIS_FORCE_APPLE_SPEECH_FALLBACK"] == nil {
    jarvisAppSwiftSettings.append(.define("APPLE_SPEECH_SDK"))
}
#endif

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
