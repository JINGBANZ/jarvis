import Foundation
import Testing
@testable import JarvisCore

@Suite struct InstalledSkillCatalogTests {
    @Test(arguments: ["", "Contents/Resources"])
    func loadsSkillsFromTheInstalledApp(layout: String) throws {
        try withApp(layout: layout) { bundle, resources in
            try writeSkill(in: resources)
            #expect(SkillCatalog.bundled(in: bundle).map(\.name) == ["fixture"])
        }
    }

    @Test(arguments: ["missing-bundle", "missing-skills", "invalid-skill"])
    func anIncompleteInstalledAppCannotUseTheSourceCheckoutOrNeighboringBundles(failure: String) throws {
        try withApp(layout: "Contents/Resources") { bundle, resources in
            let neighboring = bundle.bundleURL.deletingLastPathComponent()
                .appendingPathComponent("Jarvis_JarvisCore.bundle")
            try writeSkill(in: neighboring)
            if failure == "missing-bundle" {
                try FileManager.default.removeItem(at: resources.deletingLastPathComponent()
                    .deletingLastPathComponent())
            } else if failure == "invalid-skill" {
                try writeSkill(in: resources, text: "invalid skill")
            }
            #expect(SkillCatalog.bundled(in: bundle).isEmpty)
        }
    }

    @Test(arguments: ["", "Contents/Resources"])
    func theModelUsesTheSameInstalledBundleResolution(layout: String) throws {
        try withApp(layout: layout, resourceBundle: "Jarvis_JarvisApp") { bundle, resources in
            let model = resources.appendingPathComponent("SileroVAD.mlmodelc")
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            let loaded = try #require(JarvisResourceBundle.app.url(forResource: "SileroVAD.mlmodelc", in: bundle))
            #expect(loaded.path == model.path)
        }
    }

    private func withApp(
        layout: String,
        resourceBundle: String = "Jarvis_JarvisCore",
        body: (Bundle, URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-installed-skills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Jarvis.app")
        let resourceRoot = app.appendingPathComponent("Contents/Resources/\(resourceBundle).bundle")
        let resources = layout.isEmpty ? resourceRoot : resourceRoot.appendingPathComponent(layout)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let appInfo: [String: Any] = [
            "CFBundleIdentifier": "com.jarvis.resource-fixture.\(UUID().uuidString)",
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: appInfo, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        if !layout.isEmpty {
            try PropertyListSerialization.data(
                fromPropertyList: ["CFBundlePackageType": "BNDL"], format: .xml, options: 0)
                .write(to: resources.deletingLastPathComponent().appendingPathComponent("Info.plist"))
        }
        try body(#require(Bundle(url: app)), resources)
    }

    private func writeSkill(in resources: URL, text: String? = nil) throws {
        let skill = resources.appendingPathComponent("Skills/fixture/SKILL.md")
        try FileManager.default.createDirectory(
            at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (text ?? """
            ---
            name: fixture
            description: Installed resource fixture.
            ---
            Guidance from the installed app.
            """).write(to: skill, atomically: true, encoding: .utf8)
    }
}
