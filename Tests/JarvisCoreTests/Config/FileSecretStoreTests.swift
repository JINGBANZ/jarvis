import Foundation
import Testing
@testable import JarvisCore

/// `FileSecretStore` persists the API key in an owner-only file (no Keychain), so the key survives
/// rebuilds without a per-build authorization prompt. These tests pin the contract the app relies on:
/// a write→read roundtrip, owner-only (0600) file + (0700) directory permissions, and the
/// missing/empty cases that map to "no key yet".
@Suite struct FileSecretStoreTests {
    /// A throwaway directory URL under a unique temp directory; the store creates it itself.
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
        // A key that is only whitespace is "no key": the file store trims before checking (stricter
        // than EnvSecretStore, which doesn't trim and would return the raw whitespace).
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

    /// The whole point of the file store is to hold a secret no other local user can read.
    @Test func fileIsOwnerOnly() throws {
        let store = FileSecretStore(directoryURL: tempDirectoryURL())
        #expect(store.setApiKey("sk-perms", for: .openAIAPIKey))
        let perms = try FileManager.default.attributesOfItem(
            atPath: store.fileURL(for: .openAIAPIKey).path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
    }

    /// A 0755 parent would leak the credential file's existence/metadata to other local users, so the
    /// store must create its directory owner-only too (CWE-732).
    @Test func directoryIsOwnerOnly() throws {
        let dir = tempDirectoryURL()
        let store = FileSecretStore(directoryURL: dir)
        #expect(store.setApiKey("sk-dir", for: .openAIAPIKey))
        let perms = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o700)
    }

    /// `createDirectory` only applies its mode to directories it creates — a *pre-existing* loose dir
    /// keeps its mode. The store must tighten it anyway, or the owner-only guarantee silently lapses.
    @Test func tightensPreExistingLooseDirectory() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("jarvis-loose-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let store = FileSecretStore(directoryURL: dir)
        #expect(store.setApiKey("sk-tighten", for: .openAIAPIKey))
        let perms = try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o700)
    }

    /// Overwriting an already-saved key must re-assert 0600 — otherwise a file someone loosened (or a
    /// future switch to a perms-preserving write) would silently leave the secret world-readable.
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

    /// `setApiKey` returns false (not a crash) when the file can't be written — the path the Settings
    /// UI surfaces as "Couldn't save key". Here the intended parent is a regular file, so the store's
    /// directory creation fails.
    @Test func writeFailsGracefullyWhenDirectoryUnavailable() throws {
        let fm = FileManager.default
        let blocker = fm.temporaryDirectory.appendingPathComponent("jarvis-blocker-\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker)   // a file where the store wants a directory
        let store = FileSecretStore(directoryURL: blocker.appendingPathComponent("sub"))
        #expect(store.setApiKey("sk-nope", for: .openAIAPIKey) == false)
    }

    @Test func defaultLocationIsUnderApplicationSupport() {
        // The no-arg init must land in the per-user Application Support tree, not /tmp or cwd.
        let store = FileSecretStore()
        #expect(store.directoryURL.path.contains("Application Support/Jarvis"))
    }
}
