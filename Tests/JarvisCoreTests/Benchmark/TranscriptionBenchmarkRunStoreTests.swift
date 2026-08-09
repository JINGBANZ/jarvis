import Foundation
import Testing
@testable import JarvisCore

@Suite("Transcription benchmark run retention")
struct TranscriptionBenchmarkRunStoreTests {
    @Test("pruning retains the current run and newest past runs within the cap")
    func boundedRetention() throws {
        let base = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: base) }
        let ids = (0..<5).map { "2026-08-09_1\($0)-00-00-\($0 + 100)" }
        for id in ids {
            try FileManager.default.createDirectory(
                at: base.appendingPathComponent(id),
                withIntermediateDirectories: false)
        }
        let current = base.appendingPathComponent(ids[0])

        try TranscriptionBenchmarkRunStore(base: base, current: current)
            .pruneToMostRecent(3)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: base.path).sorted()
        #expect(remaining == [ids[0], ids[3], ids[4]].sorted())
    }

    @Test("pruning ignores unrelated directories and matching symlinks")
    func ignoresUnownedChildren() throws {
        let root = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("runs")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let current = base.appendingPathComponent("2026-08-09_12-00-00-200")
        let old = base.appendingPathComponent("2026-08-09_11-00-00-199")
        let unrelated = base.appendingPathComponent("notes")
        let linked = base.appendingPathComponent("2026-08-09_10-00-00-198")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)

        try TranscriptionBenchmarkRunStore(base: base, current: current)
            .pruneToMostRecent(1)

        #expect(FileManager.default.fileExists(atPath: current.path))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: linked.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }
}
