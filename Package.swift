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
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    ],
    targets: [
        // `.copy`, not `.process`: SkillCatalog enumerates the `<name>/SKILL.md` folders.
        .target(
            name: "JarvisCore", resources: [.copy("Resources/Skills")], swiftSettings: liveE2ESettings),
        // The ordinary spawn seam is shared by production OS adapters and executable composition.
        .target(name: "JarvisProcess"),
        .target(name: "JarvisTestSupport", dependencies: ["JarvisProcess"]),
        .target(name: "JarvisBrainProviders", dependencies: ["JarvisCore", "JarvisProcess"]),
        .target(name: "JarvisEvaluation", dependencies: ["JarvisCore", "JarvisBrainProviders", "JarvisProcess"]),
        .target(name: "JarvisOverlay", dependencies: ["JarvisCore"]),
        .target(name: "JarvisScreenCapture", dependencies: ["JarvisCore", "JarvisProcess"]),
        // The locally built universal archive takes precedence over the bundled arm64 archive.
        .target(
            name: "CJarvisAEC",
            exclude: ["lib"],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(packageRoot)/.build/aec", "-L\(packageRoot)/Sources/CJarvisAEC/lib",
                    "-ljarvis-aec",
                ]),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("c++"),
            ]
        ),
        .executableTarget(
            name: "JarvisApp",
            dependencies: [
                "JarvisCore", "JarvisBrainProviders", "JarvisEvaluation", "JarvisOverlay",
                "JarvisScreenCapture", "JarvisProcess", "JarvisTestSupport", "CJarvisAEC",
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
            name: "JarvisReferenceHelper",
            dependencies: ["JarvisCore", "JarvisProcess", "JarvisTestSupport", .product(name: "ZIPFoundation", package: "ZIPFoundation")],
            swiftSettings: liveE2ESettings,
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "EvalPrep",
            dependencies: ["JarvisEvaluation", "JarvisCore", "JarvisBrainProviders", "JarvisProcess", "JarvisTestSupport"]
        ),
        .testTarget(
            name: "JarvisCoreTests",
            // The coaching parity harness composes the kernel with the real BrainAccessor.
            dependencies: ["JarvisCore", "JarvisBrainProviders"]
        ),
        .testTarget(
            name: "JarvisBrainProvidersTests",
            dependencies: ["JarvisBrainProviders", "JarvisCore", "JarvisProcess", "JarvisTestSupport"]
        ),
        .testTarget(
            name: "JarvisEvaluationTests",
            dependencies: ["JarvisEvaluation", "JarvisCore", "JarvisBrainProviders", "JarvisTestSupport", "JarvisProcess"]
        ),
        .testTarget(
            name: "JarvisOverlayTests",
            dependencies: ["JarvisOverlay"]
        ),
        .testTarget(
            name: "JarvisScreenCaptureTests",
            dependencies: ["JarvisScreenCapture", "JarvisCore", "JarvisProcess", "JarvisTestSupport"]
        ),
        // The Gate compiles this target but never runs it; scripts/run-live-tests.sh does.
        .testTarget(
            name: "JarvisLiveTests",
            dependencies: ["JarvisCore", "JarvisBrainProviders", "JarvisEvaluation", "JarvisTestSupport", "JarvisProcess"],
            exclude: ["Fixtures", "Scenarios"]
        ),
        // Separate from JarvisCoreTests so that target stays Foundation-only.
        .testTarget(
            name: "JarvisViewerTests",
            dependencies: ["JarvisCore"]
        ),
    ]
)
