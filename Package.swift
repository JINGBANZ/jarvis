// swift-tools-version:6.0
import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

// Keeps the pre-macOS 26 Apple Speech fallback buildable on a macOS 26 SDK. SwiftPM ignores
// environment-only manifest changes, so use a clean scratch path when toggling it.
let forceAppleSpeechFallback =
    ProcessInfo.processInfo.environment["JARVIS_FORCE_APPLE_SPEECH_FALLBACK"] == "1"
let liveE2ESettings: [SwiftSetting] = [.define("JARVIS_LIVE_E2E", .when(configuration: .debug))]
let jarvisAppSwiftSettings: [SwiftSetting] = liveE2ESettings + (forceAppleSpeechFallback
    ? [.define("JARVIS_FORCE_APPLE_SPEECH_FALLBACK")]
    : [])

let package = Package(
    name: "Jarvis",
    platforms: [.macOS("14.2")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6"),
    ],
    targets: [
        // `.copy`, not `.process`: SkillCatalog enumerates the `<name>/SKILL.md` folders.
        .target(
            name: "JarvisCore", resources: [.copy("Resources/Skills")], swiftSettings: liveE2ESettings),
        .target(name: "JarvisBrainProviders", dependencies: ["JarvisCore"]),
        .target(name: "JarvisEvaluation", dependencies: ["JarvisCore", "JarvisBrainProviders"]),
        .target(name: "JarvisOverlay", dependencies: ["JarvisCore"]),
        .target(name: "JarvisScreenCapture", dependencies: ["JarvisCore"]),
        // lib/libjarvis-aec.a is prebuilt by scripts/build-aec.sh; only the C facade compiles here.
        .target(
            name: "CJarvisAEC",
            exclude: ["lib"],
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
            // Prebuilt by scripts/build-vad.sh. `.process` would flatten the .mlmodelc directory.
            resources: [.copy("Resources/SileroVAD.mlmodelc")],
            swiftSettings: jarvisAppSwiftSettings,
            // The packaging scripts embed Sparkle.framework in Contents/Frameworks.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .executableTarget(
            name: "EvalPrep",
            dependencies: ["JarvisEvaluation", "JarvisCore", "JarvisBrainProviders"]
        ),
        .testTarget(
            name: "JarvisCoreTests",
            // The coaching parity harness composes the kernel with the real BrainAccessor.
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
        // The Gate compiles this target but never runs it; scripts/run-live-tests.sh does.
        .testTarget(
            name: "JarvisLiveTests",
            dependencies: ["JarvisCore", "JarvisBrainProviders", "JarvisEvaluation"],
            exclude: ["Fixtures", "Scenarios"]
        ),
        // Separate from JarvisCoreTests so that target stays Foundation-only.
        .testTarget(
            name: "JarvisViewerTests",
            dependencies: ["JarvisCore"]
        ),
    ]
)
