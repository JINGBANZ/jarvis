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
    platforms: [.macOS("14.2")],
    dependencies: [
        // Sparkle ships as a prebuilt XCFramework through a remote binary target, so it resolves and
        // links under Command Line Tools alone — no Xcode project, matching how this package builds.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6"),
    ],
    targets: [
        .target(name: "JarvisCore"),
        // Concrete brain-provider adapters: the OpenAI Responses client with its HTTP failure
        // classification, and the local-agent CLI subtree (Claude Code, Codex exec, and the Codex
        // app server) with its detector, process runner, and runtime lifetime. Extracted per
        // wiki/lean-coaching-core.md Phase 4: Core keeps the provider-neutral BrainClient port,
        // targets, failures, model catalog, workload timeouts, and attempt contracts and describes
        // brains without running one; JarvisApp composes providers at Start. Foundation-only;
        // depends inward on JarvisCore.
        .target(name: "JarvisBrainProviders", dependencies: ["JarvisCore"]),
        // The sealed-session evaluation stack (evidence index, metrics, transcript rendering, the
        // agentic evaluator, report page). Extracted per wiki/lean-coaching-core.md Phase 3: two
        // executable consumers (JarvisApp's Evaluate flow and EvalPrep) plus a compiler-enforced
        // "never reads live coaching state" boundary. Foundation-only; depends inward on JarvisCore.
        // JarvisBrainProviders is a dependency because the agentic evaluator runs a local agent
        // CLI: it reuses the same detector, invocation shape, and process runner the local-agent
        // brain adapters use, rather than keeping a second copy of that plumbing.
        .target(name: "JarvisEvaluation", dependencies: ["JarvisCore", "JarvisBrainProviders"]),
        // The AppKit overlay lives in its own library target (not the executable) so it can be
        // imported by tests — see Tests/JarvisOverlayTests for the screen-capture invisibility checks.
        .target(name: "JarvisOverlay", dependencies: ["JarvisCore"]),
        // The OS-bound screen-capture adapter behind Core's ScreenCapturing port: the cancellable
        // `screencapture` helper process, the transient session-local JPEG, and the
        // cleanup-verification latch (wiki/lean-coaching-core.md Phase 4). A library target rather
        // than JarvisApp code so Tests/JarvisScreenCaptureTests can keep driving the
        // cancellation/cleanup/latch privacy contract headlessly, which Core's Foundation-only
        // tests no longer can once the process leaves Core.
        .target(name: "JarvisScreenCapture", dependencies: ["JarvisCore"]),
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
            dependencies: [
                "JarvisCore", "JarvisBrainProviders", "JarvisEvaluation", "JarvisOverlay",
                "JarvisScreenCapture", "CJarvisAEC",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: jarvisAppSwiftSettings,
            // Sparkle is a dynamic framework embedded at Contents/Frameworks by the packaging
            // scripts; SwiftPM builds a bare executable, so the bundle rpath is set here.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        // The dev-side CLI half of the agentic session audit (see AgenticEvaluation): renders a
        // session's traffic to a compact transcript and prints the agent task prompt. A separate,
        // Foundation-only executable so it builds/runs on any machine and scripts/eval-session.sh can
        // reuse JarvisEvaluation's transcript rendering instead of reimplementing it in bash.
        .executableTarget(
            name: "EvalPrep",
            dependencies: ["JarvisEvaluation", "JarvisCore"]
        ),
        .testTarget(
            name: "JarvisCoreTests",
            // JarvisBrainProviders is linked for two narrow reasons: the coaching parity harness
            // composes the kernel with the real OpenAI adapter over scripted transports — the same
            // composition JarvisApp performs at Start — and the provider-neutral BrainFailure tests
            // classify a real local-agent CLI error domain rather than a made-up string. Core's own
            // units keep testing against fakes.
            dependencies: ["JarvisCore", "JarvisBrainProviders"]
        ),
        .testTarget(
            name: "JarvisBrainProvidersTests",
            dependencies: ["JarvisBrainProviders", "JarvisCore"]
        ),
        .testTarget(
            name: "JarvisEvaluationTests",
            dependencies: ["JarvisEvaluation", "JarvisCore", "JarvisBrainProviders"]
        ),
        .testTarget(
            name: "JarvisOverlayTests",
            dependencies: ["JarvisOverlay"]
        ),
        .testTarget(
            name: "JarvisScreenCaptureTests",
            dependencies: ["JarvisScreenCapture", "JarvisCore"]
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
