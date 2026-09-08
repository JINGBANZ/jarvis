import Testing
import Foundation
@testable import JarvisCore

@Suite struct CredentialTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-credential-tests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func eachCredentialMapsToItsOwnFileAndEnvironmentVariable() {
        #expect(Credential.openAIAPIKey.fileName == "openai-api-key")
        #expect(Credential.geminiAPIKey.fileName == "gemini-api-key")
        #expect(Credential.openAIAPIKey.environmentVariable == "OPENAI_API_KEY")
        #expect(Credential.geminiAPIKey.environmentVariable == "GEMINI_API_KEY")
        #expect(Credential.openAIAPIKey.displayName == "OpenAI API")
        #expect(Credential.geminiAPIKey.displayName == "Gemini API")
    }

    /// Two credentials share one directory but never one file — saving Gemini must not disturb OpenAI.
    @Test func savingOneCredentialLeavesTheOtherIntact() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSecretStore(directoryURL: directory)

        #expect(store.setApiKey("sk-openai", for: .openAIAPIKey))
        #expect(store.setApiKey("gem-key", for: .geminiAPIKey))

        #expect(store.apiKey(for: .openAIAPIKey) == "sk-openai")
        #expect(store.apiKey(for: .geminiAPIKey) == "gem-key")
        #expect(store.fileURL(for: .openAIAPIKey) != store.fileURL(for: .geminiAPIKey))
        #expect(store.fileURL(for: .openAIAPIKey).deletingLastPathComponent()
            == store.fileURL(for: .geminiAPIKey).deletingLastPathComponent())
    }

    @Test func missingCredentialReadsNil() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSecretStore(directoryURL: directory)
        store.setApiKey("sk-openai", for: .openAIAPIKey)
        #expect(store.apiKey(for: .geminiAPIKey) == nil)
    }

    /// The credential file must never be group- or world-readable, and neither may its directory.
    @Test func savedCredentialIsOwnerOnlyInsideAnOwnerOnlyDirectory() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSecretStore(directoryURL: directory)
        #expect(store.setApiKey("gem-key", for: .geminiAPIKey))

        let fileMode = try FileManager.default.attributesOfItem(
            atPath: store.fileURL(for: .geminiAPIKey).path)[.posixPermissions] as? NSNumber
        let directoryMode = try FileManager.default.attributesOfItem(
            atPath: directory.path)[.posixPermissions] as? NSNumber
        #expect(fileMode?.int16Value == 0o600)
        #expect(directoryMode?.int16Value == 0o700)
    }

    @Test func environmentStoreReadsTheVariableMatchingTheCredential() {
        let store = EnvSecretStore(environment: [
            "OPENAI_API_KEY": "sk-env",
            "GEMINI_API_KEY": "gem-env",
        ])
        #expect(store.apiKey(for: .openAIAPIKey) == "sk-env")
        #expect(store.apiKey(for: .geminiAPIKey) == "gem-env")
    }

    @Test func emptyEnvironmentValueIsTreatedAsAbsent() {
        let store = EnvSecretStore(environment: ["GEMINI_API_KEY": ""])
        #expect(store.apiKey(for: .geminiAPIKey) == nil)
    }

    /// The chain forwards the credential rather than collapsing to one key.
    @Test func chainedStoreFallsBackPerCredential() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = FileSecretStore(directoryURL: directory)
        file.setApiKey("sk-file", for: .openAIAPIKey)
        let chained = ChainedSecretStore([
            file,
            EnvSecretStore(environment: ["GEMINI_API_KEY": "gem-env"]),
        ])
        #expect(chained.apiKey(for: .openAIAPIKey) == "sk-file")
        #expect(chained.apiKey(for: .geminiAPIKey) == "gem-env")
    }
}
