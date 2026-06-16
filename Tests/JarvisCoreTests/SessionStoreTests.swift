import Testing
import Foundation
@testable import JarvisCore

@Suite struct SessionStoreTests {
    /// Write a session dir with a `jarvis-activity.jsonl` (and optional shot) under `base`.
    private func makeSession(_ base: URL, _ id: String, lines: [String], shot: (String, Data)? = nil) throws {
        let d = base.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try body.write(to: d.appendingPathComponent("jarvis-activity.jsonl"), atomically: true, encoding: .utf8)
        if let (name, data) = shot { try data.write(to: d.appendingPathComponent(name)) }
    }

    @Test func listsNewestFirstWithCurrentFlagged() throws {
        let base = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: base) }
        try makeSession(base, "2026-06-16_10-00-00_aaaa", lines: ["{\"t\":\"10:00:00\",\"m\":\"x\"}"])
        try makeSession(base, "2026-06-16_11-00-00_bbbb", lines: ["{\"t\":\"11:00:00\",\"m\":\"y\"}"])
        // A non-session subdir must be ignored.
        try FileManager.default.createDirectory(at: base.appendingPathComponent("not-a-session"),
                                                withIntermediateDirectories: true)
        let cur = base.appendingPathComponent("2026-06-16_11-00-00_bbbb")
        let sessions = SessionStore(base: base, current: cur).listSessions()
        #expect(sessions.count == 2)
        #expect(sessions[0].id == "2026-06-16_11-00-00_bbbb")   // newest first
        #expect(sessions[0].isCurrent == true)
        #expect(sessions[0].label == "2026-06-16 11:00:00")
        #expect(sessions[1].isCurrent == false)
    }

    @Test func entriesDecodeTolerateMalformedAndGuardTraversal() throws {
        let base = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: base) }
        let id = "2026-06-16_10-00-00_aaaa"
        try makeSession(base, id, lines: [
            "{\"t\":\"10:00:00\",\"m\":\"hi\",\"s\":\"shot-1.jpg\"}",
            "not valid json",
            "{\"t\":\"10:00:01\",\"m\":\"evil\",\"s\":\"../escape.jpg\"}",
            "{\"t\":\"10:00:02\",\"m\":\"text only\"}",
        ], shot: ("shot-1.jpg", Data([0xFF, 0xD8, 0xFF, 0xD9])))
        let store = SessionStore(base: base, current: nil)
        let session = try #require(store.listSessions().first)
        let rows = store.entries(for: session)
        #expect(rows.count == 3)                     // malformed line skipped
        #expect(rows[0].0.message == "hi")
        #expect(rows[0].1 != nil)                    // valid shot bytes loaded
        #expect(rows[1].0.message == "evil")
        #expect(rows[1].1 == nil)                    // traversal filename → no bytes
        #expect(rows[2].1 == nil)                    // text-only line
    }

    @Test func entriesDropImageWhenShotFileMissing() throws {
        let base = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: base) }
        let id = "2026-06-16_10-00-00_aaaa"
        try makeSession(base, id, lines: ["{\"t\":\"1\",\"m\":\"m\",\"s\":\"shot-9.jpg\"}"])  // file absent
        let store = SessionStore(base: base, current: nil)
        let rows = store.entries(for: try #require(store.listSessions().first))
        #expect(rows.count == 1)
        #expect(rows[0].1 == nil)                    // missing shot degrades to text row
    }

    @Test func clearHistoryDeletesPastButSparesCurrentAndBase() throws {
        let base = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: base) }
        try makeSession(base, "2026-06-16_10-00-00_aaaa", lines: ["{\"t\":\"1\",\"m\":\"x\"}"])
        try makeSession(base, "2026-06-16_11-00-00_bbbb", lines: ["{\"t\":\"2\",\"m\":\"y\"}"])
        let cur = base.appendingPathComponent("2026-06-16_11-00-00_bbbb")
        SessionStore(base: base, current: cur).clearHistory()
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("2026-06-16_10-00-00_aaaa").path))
        #expect(FileManager.default.fileExists(atPath: cur.path))      // current spared
        #expect(FileManager.default.fileExists(atPath: base.path))     // base spared
    }
}
