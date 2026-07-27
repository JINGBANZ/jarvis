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
        // Coaching-class lines (🗣) so both sessions count as content-bearing history.
        try makeSession(base, "2026-06-16_10-00-00_aaaa", lines: ["{\"t\":\"10:00:00\",\"m\":\"🗣 heard: x\"}"])
        try makeSession(base, "2026-06-16_11-00-00_bbbb", lines: ["{\"t\":\"11:00:00\",\"m\":\"🗣 heard: y\"}"])
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

    @Test func hidesContentlessPastSessionsButKeepsCurrentAndContentful() throws {
        let base = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: base) }
        // A past session with only lifecycle/diagnostic breadcrumbs — an aborted run.
        try makeSession(base, "2026-06-16_09-00-00_aaaa", lines: [
            "{\"t\":\"09:00:00\",\"m\":\"Jarvis: session …\"}",
            "{\"t\":\"09:00:01\",\"m\":\"💭 thinking…\"}",
            "{\"t\":\"09:00:02\",\"m\":\"Jarvis realtime error event: oops\"}",
        ])
        // A typed end marker remains visible inside a real session, but is not coaching content alone.
        try makeSession(base, "2026-06-16_09-30-00_eeee", lines: [
            """
            {"t":"09:30:00","m":"⏹ session ended by user","k":"sessionEnded"}
            """,
        ])
        // A past session that actually coached (has a 💬 line) — keep it.
        try makeSession(base, "2026-06-16_10-00-00_bbbb", lines: ["{\"t\":\"10:00:00\",\"m\":\"💬 try this\"}"])
        // A past session whose only content is a screenshot reference — keep it.
        try makeSession(base, "2026-06-16_10-30-00_cccc", lines: [
            "{\"t\":\"10:30:00\",\"m\":\"👁 looking at your screen\",\"s\":\"shot-1.jpg\"}"
        ], shot: ("shot-1.jpg", Data([0xFF, 0xD8, 0xFF, 0xD9])))
        // The current session, breadcrumbs only — always shown so the live run appears in the picker.
        try makeSession(base, "2026-06-16_11-00-00_dddd", lines: ["{\"t\":\"11:00:00\",\"m\":\"Jarvis: coaching started.\"}"])

        let cur = base.appendingPathComponent("2026-06-16_11-00-00_dddd")
        let ids = SessionStore(base: base, current: cur).listSessions().map(\.id)
        #expect(ids == ["2026-06-16_11-00-00_dddd",   // current, kept despite breadcrumbs-only
                        "2026-06-16_10-30-00_cccc",   // has a screenshot
                        "2026-06-16_10-00-00_bbbb"])  // has a coaching line
        #expect(!ids.contains("2026-06-16_09-00-00_aaaa"))   // aborted run hidden
        #expect(!ids.contains("2026-06-16_09-30-00_eeee"))   // end-only run hidden
    }

    @Test func entriesDecodeTolerateMalformedAndGuardTraversal() throws {
        let base = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: base) }
        let id = "2026-06-16_10-00-00_aaaa"
        try makeSession(base, id, lines: [
            "{\"t\":\"10:00:00\",\"m\":\"👁 looking at your screen\",\"s\":\"shot-1.jpg\"}",
            "not valid json",
            "{\"t\":\"10:00:01\",\"m\":\"evil\",\"s\":\"../escape.jpg\"}",
            "{\"t\":\"10:00:02\",\"m\":\"🗣 heard (me): text only\"}",
            "{\"t\":\"10:00:03\",\"m\":\"💭 thinking…\"}",
            "{\"t\":\"10:00:04\",\"m\":\"🤫 stayed silent — nothing useful to add\"}",
            """
            {"t":"10:00:05","m":"⏹ session ended by user","k":"sessionEnded"}
            """,
        ], shot: ("shot-1.jpg", Data([0xFF, 0xD8, 0xFF, 0xD9])))
        let store = SessionStore(base: base, current: nil)
        let session = try #require(store.listSessions().first)
        let rows = store.entries(for: session)
        #expect(rows.count == 4)                     // malformed + diagnostic rows skipped
        #expect(rows[0].0.message == "👁 looking at your screen")
        #expect(rows[0].1 != nil)                    // valid shot bytes loaded
        #expect(rows[1].0.message == "🗣 heard (me): text only")
        #expect(rows[1].1 == nil)                    // text-only coaching line
        #expect(rows[2].0.message.contains("stayed silent"))
        #expect(rows[3].0.message.contains("session ended by user"))
    }

    @Test func entriesDropImageWhenShotFileMissing() throws {
        let base = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: base) }
        let id = "2026-06-16_10-00-00_aaaa"
        try makeSession(base, id, lines: [
            "{\"t\":\"1\",\"m\":\"👁 looking at your screen\",\"s\":\"shot-9.jpg\"}"
        ])  // file absent
        let store = SessionStore(base: base, current: nil)
        let rows = store.entries(for: try #require(store.listSessions().first))
        #expect(rows.count == 1)
        #expect(rows[0].1 == nil)                    // missing shot degrades to text row
    }

    @Test func typedRouteEventsRemainVisibleWhenSessionIsReopened() throws {
        let base = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: base) }
        let id = "2026-06-16_10-00-00_aaaa"
        try makeSession(base, id, lines: [
            """
            {"t":"10:00:00","m":"⚠️ OpenAI API couldn't respond — continuing on Claude Code",\
            "k":"brainRouteAdvanced"}
            """,
            """
            {"t":"10:00:01","m":"⚠️ Codex CLI target is unavailable — skipping it",\
            "k":"brainRouteTargetSkipped"}
            """,
        ])

        let store = SessionStore(base: base, current: nil)
        let session = try #require(store.listSessions().first)
        let rows = store.entries(for: session)
        #expect(rows.map(\.0.message) == [
            "⚠️ OpenAI API couldn't respond — continuing on Claude Code",
            "⚠️ Codex CLI target is unavailable — skipping it",
        ])
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

    @Test func pruneKeepsNewestNDeletesOlderAndSparesCurrent() throws {
        let base = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: base) }
        let exists = { (id: String) in
            FileManager.default.fileExists(atPath: base.appendingPathComponent(id).path)
        }
        // Five sessions, oldest→newest. Include a content-less one (it still counts toward the cap, even
        // though listSessions would hide it) and a non-session dir that must be left untouched.
        let ids = (0..<5).map { "2026-06-16_1\($0)-00-00_aaaa" }
        for id in ids { try makeSession(base, id, lines: ["{\"t\":\"1\",\"m\":\"🗣 heard\"}"]) }
        try makeSession(base, "2026-06-16_09-00-00_zzzz", lines: [])   // content-less, oldest
        try FileManager.default.createDirectory(at: base.appendingPathComponent("keepme"),
                                                withIntermediateDirectories: true)
        // Current is the oldest *real* session: must be spared even though it falls outside the newest-3.
        let cur = base.appendingPathComponent(ids[0])
        SessionStore(base: base, current: cur).pruneToMostRecent(3)

        #expect(exists(ids[4]) && exists(ids[3]) && exists(ids[2]))   // newest 3 kept
        #expect(!exists(ids[1]))                                       // older pruned
        #expect(!exists("2026-06-16_09-00-00_zzzz"))                   // content-less also pruned
        #expect(exists(ids[0]))                                        // current spared despite being old
        #expect(exists("keepme"))                                      // non-session dir untouched
    }

    @Test func pruneTreatsNonPositiveKeepAsOneSoCurrentSurvives() throws {
        let base = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: base) }
        try makeSession(base, "2026-06-16_10-00-00_aaaa", lines: ["{\"t\":\"1\",\"m\":\"x\"}"])
        let cur = base.appendingPathComponent("2026-06-16_10-00-00_aaaa")
        SessionStore(base: base, current: cur).pruneToMostRecent(0)
        #expect(FileManager.default.fileExists(atPath: cur.path))   // never deletes the session being written
    }
}
