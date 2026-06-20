import Foundation
import Testing
@testable import JarvisCore

/// `FileSecretStore` persists the API key in an owner-only file (no Keychain), so the key survives
/// rebuilds without a per-build authorization prompt. These tests pin the contract the app relies on:
/// a write→read roundtrip, owner-only (0600) file + (0700) directory permissions, and the
/// missing/empty cases that map to "no key yet".
@Suite struct FileSecretStoreTests {
    /// A throwaway file URL under a unique temp directory; the store creates the parent itself.
    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-secret-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("openai-api-key")
    }

    @Test func writesThenReadsBack() {
        let store = FileSecretStore(fileURL: tempFileURL())
        #expect(store.setApiKey("sk-roundtrip"))
        #expect(store.apiKey() == "sk-roundtrip")
    }

    @Test func missingFileReadsAsNil() {
        let store = FileSecretStore(fileURL: tempFileURL())
        #expect(store.apiKey() == nil)
    }

    @Test func emptyOrWhitespaceReadsAsNil() {
        let url = tempFileURL()
        let store = FileSecretStore(fileURL: url)
        #expect(store.setApiKey("   \n  "))
        // A key that is only whitespace is "no key" — same as the env store's empty handling.
        #expect(store.apiKey() == nil)
    }

    @Test func surroundingWhitespaceIsTrimmed() {
        let store = FileSecretStore(fileURL: tempFileURL())
        #expect(store.setApiKey("  sk-padded\n"))
        #expect(store.apiKey() == "sk-padded")
    }

    @Test func overwriteReplacesPreviousKey() {
        let store = FileSecretStore(fileURL: tempFileURL())
        #expect(store.setApiKey("sk-old"))
        #expect(store.setApiKey("sk-new"))
        #expect(store.apiKey() == "sk-new")
    }

    /// The whole point of the file store is to hold a secret no other local user can read.
    @Test func fileIsOwnerOnly() throws {
        let url = tempFileURL()
        let store = FileSecretStore(fileURL: url)
        #expect(store.setApiKey("sk-perms"))
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
    }

    /// A 0755 parent would leak the credential file's existence/metadata to other local users, so the
    /// store must create its directory owner-only too (CWE-732).
    @Test func directoryIsOwnerOnly() throws {
        let url = tempFileURL()
        let store = FileSecretStore(fileURL: url)
        #expect(store.setApiKey("sk-dir"))
        let dir = url.deletingLastPathComponent().path
        let perms = try FileManager.default.attributesOfItem(atPath: dir)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o700)
    }

    @Test func defaultLocationIsUnderApplicationSupport() {
        // The no-arg init must land in the per-user Application Support tree, not /tmp or cwd.
        let store = FileSecretStore()
        #expect(store.fileURL.path.contains("Application Support/Jarvis"))
    }
}
