import Foundation
import Testing
@testable import JarvisCore

@Suite struct FileSecretStoreTests {
    private func tempDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-secret-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func writesThenReadsBack() {
        let store = FileSecretStore(directoryURL: tempDirectoryURL())
        #expect(store.setApiKey("sk-roundtrip", for: .openAIAPIKey))
        #expect(store.apiKey(for: .openAIAPIKey) == "sk-roundtrip")
    }

    @Test func missingFileReadsAsNil() {
        let store = FileSecretStore(directoryURL: tempDirectoryURL())
        #expect(store.apiKey(for: .openAIAPIKey) == nil)
    }

    @Test func emptyOrWhitespaceReadsAsNil() {
        let store = FileSecretStore(directoryURL: tempDirectoryURL())
        #expect(store.setApiKey("   \n  ", for: .openAIAPIKey))
        #expect(store.apiKey(for: .openAIAPIKey) == nil)
    }

    @Test func surroundingWhitespaceIsTrimmed() {
        let store = FileSecretStore(directoryURL: tempDirectoryURL())
        #expect(store.setApiKey("  sk-padded\n", for: .openAIAPIKey))
        #expect(store.apiKey(for: .openAIAPIKey) == "sk-padded")
    }

    @Test func overwriteReplacesPreviousKey() {
        let store = FileSecretStore(directoryURL: tempDirectoryURL())
        #expect(store.setApiKey("sk-old", for: .openAIAPIKey))
        #expect(store.setApiKey("sk-new", for: .openAIAPIKey))
        #expect(store.apiKey(for: .openAIAPIKey) == "sk-new")
    }

    @Test func fileIsOwnerOnly() throws {
        let store = FileSecretStore(directoryURL: tempDirectoryURL())
        #expect(store.setApiKey("sk-perms", for: .openAIAPIKey))
        let perms = try FileManager.default.attributesOfItem(
            atPath: store.fileURL(for: .openAIAPIKey).path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
    }

    /// A 0755 parent leaks the key file's existence and metadata to other local users.
    @Test func directoryIsOwnerOnly() throws {
        let dir = tempDirectoryURL()
        let store = FileSecretStore(directoryURL: dir)
        #expect(store.setApiKey("sk-dir", for: .openAIAPIKey))
        let perms = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o700)
    }

    /// `createDirectory` applies its mode only to directories it creates.
    @Test func tightensPreExistingLooseDirectory() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("jarvis-loose-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let store = FileSecretStore(directoryURL: dir)
        #expect(store.setApiKey("sk-tighten", for: .openAIAPIKey))
        let perms = try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o700)
    }

    @Test func overwriteReassertsOwnerOnlyPermissions() throws {
        let fm = FileManager.default
        let store = FileSecretStore(directoryURL: tempDirectoryURL())
        #expect(store.setApiKey("sk-first", for: .openAIAPIKey))
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.fileURL(for: .openAIAPIKey).path)
        #expect(store.setApiKey("sk-second", for: .openAIAPIKey))
        let perms = try fm.attributesOfItem(
            atPath: store.fileURL(for: .openAIAPIKey).path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
    }

    @Test func writeFailsGracefullyWhenDirectoryUnavailable() throws {
        let fm = FileManager.default
        let blocker = fm.temporaryDirectory.appendingPathComponent("jarvis-blocker-\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker)
        let store = FileSecretStore(directoryURL: blocker.appendingPathComponent("sub"))
        #expect(store.setApiKey("sk-nope", for: .openAIAPIKey) == false)
    }

    @Test func defaultLocationIsUnderApplicationSupport() {
        let store = FileSecretStore()
        #expect(store.directoryURL.path.contains("Application Support/Jarvis"))
    }
}
