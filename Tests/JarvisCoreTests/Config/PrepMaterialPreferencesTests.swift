import Testing
import Foundation
@testable import JarvisCore

@Suite struct PrepMaterialPreferencesTests {
    /// A fresh, isolated UserDefaults suite per test so nothing touches the real app domain.
    private func freshDefaults() -> UserDefaults {
        let suite = "PrepMaterialPreferencesTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func emptyWhenUnset() {
        #expect(PrepMaterialPreferences(defaults: freshDefaults()).sources
            == Defaults.PrepMaterial.sources)
    }

    @Test func roundTripsThroughDefaults() {
        let d = freshDefaults()
        let source = PrepMaterialSource(path: "/tmp/notes.md", isDirectory: false)
        PrepMaterialPreferences(defaults: d).sources = [source]
        #expect(PrepMaterialPreferences(defaults: d).sources == [source])
    }

    @Test func addAppendsInOrder() {
        let p = PrepMaterialPreferences(defaults: freshDefaults())
        let first = PrepMaterialSource(path: "/tmp/a.md", isDirectory: false)
        let second = PrepMaterialSource(path: "/tmp/b", isDirectory: true)
        p.add(first)
        p.add(second)
        #expect(p.sources.map(\.path) == ["/tmp/a.md", "/tmp/b"])
    }

    @Test func addIgnoresDuplicatePath() {
        let p = PrepMaterialPreferences(defaults: freshDefaults())
        p.add(PrepMaterialSource(path: "/tmp/a.md", isDirectory: false))
        p.add(PrepMaterialSource(path: "/tmp/a.md", isDirectory: false))
        #expect(p.sources.count == 1)
    }

    @Test func removeDropsOnlyTheMatchingId() {
        let p = PrepMaterialPreferences(defaults: freshDefaults())
        let keep = PrepMaterialSource(path: "/tmp/keep.md", isDirectory: false)
        let drop = PrepMaterialSource(path: "/tmp/drop.md", isDirectory: false)
        p.sources = [keep, drop]
        p.remove(id: drop.id)
        #expect(p.sources == [keep])
    }

    @Test func malformedPersistedEntryIsDropped() {
        // A hand-edited or stale plist entry must never crash a read.
        let d = freshDefaults()
        d.set([["id": "not-a-uuid", "path": "/tmp/a.md", "isDirectory": false]],
              forKey: "prepMaterial.sources")
        #expect(PrepMaterialPreferences(defaults: d).sources.isEmpty)
    }

    @Test func displayNameIsLastPathComponent() {
        let source = PrepMaterialSource(path: "/Users/me/Notes/system-design.md", isDirectory: false)
        #expect(source.displayName == "system-design.md")
    }

    @Test func existsReflectsLiveFilesystemState() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        let source = PrepMaterialSource(path: path, isDirectory: false)
        #expect(!source.exists())
        FileManager.default.createFile(atPath: path, contents: Data())
        #expect(source.exists())
        try? FileManager.default.removeItem(atPath: path)
    }
}
