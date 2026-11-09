import Foundation
import Testing
@testable import JarvisScenarioHarness

@Suite struct InstalledTestProviderConfigurationTests {
    @Test(arguments: ["", "Contents/Resources"])
    func loadsDefaultsFromTheInstalledApp(layout: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-installed-test-providers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Jarvis.app")
        let resourceRoot = app.appendingPathComponent(
            "Contents/Resources/Jarvis_JarvisScenarioHarness.bundle")
        let resources = layout.isEmpty ? resourceRoot : resourceRoot.appendingPathComponent(layout)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "com.jarvis.test-provider-fixture.\(UUID().uuidString)",
            "CFBundlePackageType": "APPL",
        ], format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        if !layout.isEmpty {
            try PropertyListSerialization.data(
                fromPropertyList: ["CFBundlePackageType": "BNDL"], format: .xml, options: 0)
                .write(to: resources.deletingLastPathComponent().appendingPathComponent("Info.plist"))
        }
        try """
        {"defaultProvider":"openai","defaultJudgeProvider":"gemini",
         "models":{"openai":"installed-coach"},"judgeModels":{"gemini":"installed-judge"}}
        """.write(to: resources.appendingPathComponent("test-providers.json"),
            atomically: true, encoding: .utf8)

        let loaded = try TestProviderConfiguration.load(in: #require(Bundle(url: app)))
        #expect(loaded.defaultProvider == .openAI)
        #expect(loaded.defaultJudgeProvider == .gemini)
        #expect(loaded.modelID(for: .openAI) == "installed-coach")
        #expect(loaded.modelID(for: .gemini, judge: true) == "installed-judge")
    }
}
