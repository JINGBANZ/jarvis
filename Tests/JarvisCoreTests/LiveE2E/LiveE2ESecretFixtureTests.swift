import Foundation
import Testing
@testable import JarvisCore

@Suite struct LiveE2ESecretFixtureTests {
    private static let liveTests = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("JarvisLiveTests", isDirectory: true)
    private static let fixtures = liveTests.appendingPathComponent("Fixtures", isDirectory: true)

    @Test(arguments: BrainProvider.allCases)
    func invalidTranscriptionPreservesSelectedBrainKey(provider: BrainProvider) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-live-secrets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FileSecretStore(directoryURL: root)
        try #require(source.setApiKey("fake-valid-openai", for: .openAIAPIKey))
        try #require(source.setApiKey("fake-valid-gemini", for: .geminiAPIKey))

        let destination = root.appendingPathComponent("F02-secrets", isDirectory: true)
        let scenario = try scenario(provider)
        let result = try scenario.makeInvalidKeyDirectory(at: destination, using: source)
        #expect(result == destination)
        let store = FileSecretStore(directoryURL: result)
        #expect(store.apiKey(for: .openAIAPIKey) == "sk-jarvis-live-e2e-invalid-key")
        #expect(store.apiKey(for: .geminiAPIKey) == (provider == .gemini ? "fake-valid-gemini" : nil))
        #expect(source.apiKey(for: .openAIAPIKey) == "fake-valid-openai")
        #expect(source.apiKey(for: .geminiAPIKey) == "fake-valid-gemini")

        let attributes = try FileManager.default.attributesOfItem(atPath: result.path)
        #expect(attributes[.posixPermissions] as? NSNumber == 0o700)
        for credential in Credential.allCases where store.apiKey(for: credential) != nil {
            let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL(for: credential).path)
            #expect(attributes[.posixPermissions] as? NSNumber == 0o600)
        }
    }

    @Test func missingSelectedBrainKeyFailsSetup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-live-secrets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let scenario = try scenario(.gemini)
        #expect(throws: CocoaError.self) {
            try scenario.makeInvalidKeyDirectory(
                at: root.appendingPathComponent("F02-secrets", isDirectory: true),
                using: EnvSecretStore(environment: [:]))
        }
    }

    private func scenario(_ provider: BrainProvider) throws -> LiveE2EScenario {
        let source = try Data(contentsOf: Self.liveTests.appendingPathComponent("Scenarios/F02.json"))
        return try LiveE2EScenario.decode(
            LiveE2EScenario.selectingProvider(provider, in: source, fixturesDirectory: Self.fixtures),
            fixturesDirectory: Self.fixtures)
    }
}
