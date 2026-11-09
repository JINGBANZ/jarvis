// swift-tools-version:6.0
import PackageDescription
import Foundation

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
            name: "JarvisCore", resources: [.copy("Resources/Skills")]),
        // The ordinary spawn seam is shared by production OS adapters and executable composition.
        .target(name: "JarvisProcess"),
        .target(name: "JarvisTestProcesses", dependencies: ["JarvisProcess"], path: "Tests/Support/ProcessOwnership"),
        .target(name: "JarvisTestDisplay", path: "Tests/Support/TestDisplay"),
        .target(name: "JarvisTestHost", path: "Tests/Support/TestHost"),
        .target(name: "JarvisScenarioHarness", dependencies: ["JarvisCore", "JarvisBrainProviders", "JarvisProcess"], path: "Tests/Support/ScenarioHarness", resources: [.copy("Resources/test-providers.json")], swiftSettings: liveE2ESettings),
        .target(name: "JarvisBrainProviders", dependencies: ["JarvisCore", "JarvisProcess"]),
        .target(name: "JarvisEvaluation", dependencies: ["JarvisCore", "JarvisBrainProviders", "JarvisProcess"]),
        .target(name: "JarvisOverlay", dependencies: ["JarvisCore"]),
        .target(name: "JarvisScreenCapture", dependencies: ["JarvisCore", "JarvisProcess"]),
        .binaryTarget(
            name: "CJarvisAEC",
            url: "https://github.com/JINGBANZ/jarvis/releases/download/aec-v2.1.0/CJarvisAEC.xcframework.zip",
            checksum: "9ec3fde5773ac8e7204a62b3bf2d4fa1d5c41b496f37361ab07b0c8a0120e83c"
        ),
        .testTarget(name: "JarvisAECTests", dependencies: ["CJarvisAEC"]),
        .executableTarget(
            name: "JarvisApp",
            dependencies: [
                "JarvisCore", "JarvisBrainProviders", "JarvisEvaluation", "JarvisOverlay",
                "JarvisScreenCapture", "JarvisProcess", "JarvisTestProcesses", "JarvisScenarioHarness", "CJarvisAEC",
                "JarvisTestDisplay",
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
            dependencies: ["JarvisCore", "JarvisProcess", "JarvisTestProcesses", .product(name: "ZIPFoundation", package: "ZIPFoundation")],
            swiftSettings: liveE2ESettings,
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "EvalPrep",
            dependencies: ["JarvisEvaluation", "JarvisCore", "JarvisBrainProviders", "JarvisProcess", "JarvisTestProcesses"]
        ),
        .testTarget(
            name: "JarvisCoreTests",
            // The coaching parity harness composes the kernel with the real BrainAccessor.
            dependencies: ["JarvisCore", "JarvisBrainProviders"]
        ),
        .testTarget(
            name: "JarvisBrainProvidersTests",
            dependencies: ["JarvisBrainProviders", "JarvisCore", "JarvisProcess", "JarvisTestProcesses"]
        ),
        .testTarget(
            name: "JarvisEvaluationTests",
            dependencies: ["JarvisEvaluation", "JarvisCore", "JarvisBrainProviders", "JarvisTestProcesses", "JarvisProcess"]
        ),
        .testTarget(
            name: "JarvisOverlayTests",
            dependencies: ["JarvisOverlay", "JarvisTestDisplay"]
        ),
        .testTarget(
            name: "JarvisScreenCaptureTests",
            dependencies: ["JarvisScreenCapture", "JarvisCore", "JarvisProcess", "JarvisTestProcesses"]
        ),
        .testTarget(name: "JarvisScenarioHarnessTests", dependencies: ["JarvisScenarioHarness", "JarvisCore", "JarvisBrainProviders", "JarvisProcess"]),
        // The Gate compiles this target but never runs it; scripts/run-live-tests.sh does.
        .testTarget(
            name: "JarvisLiveTests",
            dependencies: ["JarvisCore", "JarvisBrainProviders", "JarvisEvaluation", "JarvisScenarioHarness", "JarvisTestProcesses", "JarvisProcess"],
            exclude: ["Fixtures", "Scenarios"]
        ),
        // Separate from JarvisCoreTests so that target stays Foundation-only.
        .testTarget(
            name: "JarvisViewerTests",
            dependencies: ["JarvisCore"]
        ),
    ]
)

// Swift Build creates a separate test product per target; each must register before discovery.
for target in package.targets where target.type == .test {
    target.dependencies.append("JarvisTestHost")
    target.linkerSettings = (target.linkerSettings ?? []) + [
        .unsafeFlags(["-Xlinker", "-u", "-Xlinker", "_jarvis_test_host_link"]),
    ]
}
