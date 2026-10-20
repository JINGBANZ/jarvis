import Testing
import Foundation
@testable import JarvisCore

@Suite struct ReferencePreferencesTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "ReferencePreferencesTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func emptyWhenUnset() {
        #expect(ReferencePreferences(defaults: freshDefaults()).sources
            == Defaults.References.sources)
    }

    @Test func roundTripsThroughDefaults() {
        let d = freshDefaults()
        let source = ReferenceSourceSelection(path: "/tmp/notes.md", isDirectory: false)
        ReferencePreferences(defaults: d).sources = [source]
        #expect(ReferencePreferences(defaults: d).sources == [source])
    }

    @Test func preservesExistingReferenceSelections() {
        let defaults = freshDefaults()
        let id = UUID()
        defaults.set([["id": id.uuidString, "path": "/tmp/design.md", "isDirectory": false]],
                     forKey: "prepMaterial.sources")
        let preferences = ReferencePreferences(defaults: defaults)
        #expect(preferences.sources == [.init(id: id, path: "/tmp/design.md", isDirectory: false)])
        preferences.add(.init(path: "/tmp/references", isDirectory: true))
        #expect(defaults.array(forKey: "prepMaterial.sources")?.count == 2)
        #expect(ReferencePreferences(defaults: defaults).sources.map(\.id).first == id)
    }

    @Test func addAppendsInOrder() {
        let p = ReferencePreferences(defaults: freshDefaults())
        let first = ReferenceSourceSelection(path: "/tmp/a.md", isDirectory: false)
        let second = ReferenceSourceSelection(path: "/tmp/b", isDirectory: true)
        p.add(first)
        p.add(second)
        #expect(p.sources.map(\.path) == ["/tmp/a.md", "/tmp/b"])
    }

    @Test func addIgnoresDuplicatePath() {
        let p = ReferencePreferences(defaults: freshDefaults())
        p.add(ReferenceSourceSelection(path: "/tmp/a.md", isDirectory: false))
        p.add(ReferenceSourceSelection(path: "/tmp/a.md", isDirectory: false))
        #expect(p.sources.count == 1)
    }

    @Test func removeDropsOnlyTheMatchingId() {
        let p = ReferencePreferences(defaults: freshDefaults())
        let keep = ReferenceSourceSelection(path: "/tmp/keep.md", isDirectory: false)
        let drop = ReferenceSourceSelection(path: "/tmp/drop.md", isDirectory: false)
        p.sources = [keep, drop]
        p.remove(id: drop.id)
        #expect(p.sources == [keep])
    }

    @Test func malformedPersistedEntryIsDropped() {
        let d = freshDefaults()
        d.set([["id": "not-a-uuid", "path": "/tmp/a.md", "isDirectory": false]],
              forKey: "prepMaterial.sources")
        #expect(ReferencePreferences(defaults: d).sources.isEmpty)
    }

    @Test func displayNameIsLastPathComponent() {
        let source = ReferenceSourceSelection(path: "/Users/me/Notes/system-design.md", isDirectory: false)
        #expect(source.displayName == "system-design.md")
    }

    @Test func existsReflectsLiveFilesystemState() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        let source = ReferenceSourceSelection(path: path, isDirectory: false)
        #expect(!source.exists())
        FileManager.default.createFile(atPath: path, contents: Data())
        #expect(source.exists())
        try? FileManager.default.removeItem(atPath: path)
    }
}
