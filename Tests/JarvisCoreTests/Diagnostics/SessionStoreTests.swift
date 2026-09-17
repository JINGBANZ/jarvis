import Testing
import Foundation
@testable import JarvisCore

@Suite struct SessionStoreTests {
    @Test func developmentHistoryIsIsolatedPerWorktreeAndFromRelease() throws {
        let root = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: root) }
        let appData = root.appendingPathComponent("Application Support/Jarvis")
        let firstWorktree = root.appendingPathComponent("main checkout")
        let secondWorktree = root.appendingPathComponent("feature worktree")
        let first = SessionStore.baseDirectory(isDevelopmentBuild: true,
            bundleURL: firstWorktree.appendingPathComponent("Jarvis Dev.app"), appDataDirectory: appData)
        let second = SessionStore.baseDirectory(isDevelopmentBuild: true,
            bundleURL: secondWorktree.appendingPathComponent("Jarvis Dev.app"), appDataDirectory: appData)
        let release = SessionStore.baseDirectory(isDevelopmentBuild: false,
            bundleURL: root.appendingPathComponent("Applications/Jarvis.app"), appDataDirectory: appData)
        #expect(first == firstWorktree.appendingPathComponent(".jarvis", isDirectory: true))
        #expect(second == secondWorktree.appendingPathComponent(".jarvis", isDirectory: true))
        #expect(release == appData.appendingPathComponent("sessions", isDirectory: true))
        for base in [first, second, release] { #expect(!FileManager.default.fileExists(atPath: base.path)) }
        let ids = ["dev-2026-09-12_10-00-00_aaaa", "dev-2026-09-12_11-00-00_bbbb",
                   "v0.2.2-2026-09-12_12-00-00_cccc"]
        for (base, id) in zip([first, second, release], ids) {
            try makeSession(base, id, lines: [#"{"t":"10:00:00","m":"heard question","k":"heard"}"#])
            #expect(SessionStore(base: base, current: nil).listSessions().map(\.id) == [id])
        }
        SessionStore(base: first, current: nil).clearHistory()
        #expect(SessionStore(base: first, current: nil).listSessions().isEmpty)
        #expect(SessionStore(base: second, current: nil).listSessions().map(\.id) == [ids[1]])
        #expect(SessionStore(base: release, current: nil).listSessions().map(\.id) == [ids[2]])
    }

    @Test func releaseHistoryDoesNotDependOnBundleLocation() {
        let appData = URL(fileURLWithPath: "/user/Application Support/Jarvis", isDirectory: true)
        for bundle in ["/Applications/Jarvis.app", "/Volumes/Jarvis/Jarvis.app"] {
            #expect(SessionStore.baseDirectory(isDevelopmentBuild: false,
                bundleURL: URL(fileURLWithPath: bundle), appDataDirectory: appData)
                == appData.appendingPathComponent("sessions", isDirectory: true))
        }
    }

    @Test func prefixedAndOldSessionsShareChronologyAndRetention() throws {
        let base = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: base) }
        let ids = ["v9.0.0-2026-09-12_09-00-00_aaaa", "v0.2.2-2026-09-12_10-00-00_bbbb",
                   "2026-09-12_11-00-00_cccc", "dev-2026-09-12_12-00-00_dddd"]
        for id in ids {
            try makeSession(base, id, lines: [#"{"t":"10:00:00","m":"heard question","k":"heard"}"#])
        }
        let current = base.appendingPathComponent(ids[3])
        let store = SessionStore(base: base, current: current)
        #expect(store.listSessions().map(\.id) == Array(ids.reversed()))
        #expect(store.listSessions().first?.label == "2026-09-12 12:00:00")
        #expect(store.newestSessionDirectory()?.lastPathComponent == ids[3])
        store.pruneToMostRecent(2)
        #expect(store.listSessions().map(\.id) == [ids[3], ids[2]])
        store.clearHistory()
        #expect(store.listSessions().map(\.id) == [ids[3]])
    }

    private func makeSession(_ base: URL, _ id: String, lines: [String], shot: (String, Data)? = nil) throws {
        let d = base.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try body.write(to: d.appendingPathComponent("jarvis-activity.jsonl"), atomically: true, encoding: .utf8)
        if let (name, data) = shot { try data.write(to: d.appendingPathComponent(name)) }
    }

    @Test func historyReportsEvidenceCompletenessFromTheHealthRecord() throws {
        let base = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: base) }
        let heard = "{\"t\":\"10:00:00\",\"m\":\"🗣 heard: x\"}"
        try makeSession(base, "2026-06-16_10-00-00_aaaa", lines: [heard])
        try makeSession(base, "2026-06-16_11-00-00_bbbb", lines: [heard])
        try makeSession(base, "2026-06-16_12-00-00_cccc", lines: [heard])
        try makeSession(base, "2026-06-16_13-00-00_dddd", lines: [heard])
        try writeHealth(base, "2026-06-16_11-00-00_bbbb", state: "complete")
        try writeHealth(base, "2026-06-16_12-00-00_cccc", state: "partial")
        try writeHealth(base, "2026-06-16_13-00-00_dddd", state: "in_progress")

        let sessions = SessionStore(base: base, current: nil).listSessions()
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        #expect(byID["2026-06-16_11-00-00_bbbb"]?.evidenceIsComplete == true)
        #expect(byID["2026-06-16_12-00-00_cccc"]?.evidenceIsComplete == false)
        #expect(byID["2026-06-16_13-00-00_dddd"]?.evidenceIsComplete == false)
        #expect(byID["2026-06-16_10-00-00_aaaa"]?.evidenceIsComplete == nil)
    }

    private func writeHealth(_ base: URL, _ id: String, state: String) throws {
        let object: [String: Any] = ["version": FileSessionAudit.formatVersion, "state": state]
        try JSONSerialization.data(withJSONObject: object).write(
            to: base.appendingPathComponent(id)
                .appendingPathComponent(FileSessionAudit.healthFilename))
    }

    @Test func listsNewestFirstWithCurrentFlagged() throws {
        let base = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: base) }
        // 🗣 lines make both sessions content-bearing, so neither is hidden.
        try makeSession(base, "2026-06-16_10-00-00_aaaa", lines: ["{\"t\":\"10:00:00\",\"m\":\"🗣 heard: x\"}"])
        try makeSession(base, "2026-06-16_11-00-00_bbbb", lines: ["{\"t\":\"11:00:00\",\"m\":\"🗣 heard: y\"}"])
        try FileManager.default.createDirectory(at: base.appendingPathComponent("not-a-session"),
                                                withIntermediateDirectories: true)
        let cur = base.appendingPathComponent("2026-06-16_11-00-00_bbbb")
        let sessions = SessionStore(base: base, current: cur).listSessions()
        #expect(sessions.count == 2)
        #expect(sessions[0].id == "2026-06-16_11-00-00_bbbb")
        #expect(sessions[0].isCurrent == true)
        #expect(sessions[0].label == "2026-06-16 11:00:00")
        #expect(sessions[1].isCurrent == false)
    }

    @Test func hidesContentlessPastSessionsButKeepsCurrentAndContentful() throws {
        let base = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: base) }
        try makeSession(base, "2026-06-16_09-00-00_aaaa", lines: [
            "{\"t\":\"09:00:00\",\"m\":\"Jarvis: session …\"}",
            "{\"t\":\"09:00:01\",\"m\":\"💭 thinking…\"}",
            "{\"t\":\"09:00:02\",\"m\":\"Jarvis realtime error event: oops\"}",
        ])
        try makeSession(base, "2026-06-16_09-30-00_eeee", lines: [
            """
            {"t":"09:30:00","m":"⏹ session ended by user","k":"sessionEnded"}
            """,
        ])
        try makeSession(base, "2026-06-16_10-00-00_bbbb", lines: ["{\"t\":\"10:00:00\",\"m\":\"💬 try this\"}"])
        try makeSession(base, "2026-06-16_10-30-00_cccc", lines: [
            "{\"t\":\"10:30:00\",\"m\":\"👁 looking at your screen\",\"s\":\"shot-1.jpg\"}"
        ], shot: ("shot-1.jpg", Data([0xFF, 0xD8, 0xFF, 0xD9])))
        try makeSession(base, "2026-06-16_11-00-00_dddd", lines: ["{\"t\":\"11:00:00\",\"m\":\"Jarvis: coaching started.\"}"])

        let cur = base.appendingPathComponent("2026-06-16_11-00-00_dddd")
        let ids = SessionStore(base: base, current: cur).listSessions().map(\.id)
        #expect(ids == ["2026-06-16_11-00-00_dddd",
                        "2026-06-16_10-30-00_cccc",
                        "2026-06-16_10-00-00_bbbb"])
        #expect(!ids.contains("2026-06-16_09-00-00_aaaa"))
        #expect(!ids.contains("2026-06-16_09-30-00_eeee"))
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
        #expect(rows.count == 4)                     // malformed and diagnostic rows are skipped
        #expect(rows[0].0.message == "👁 looking at your screen")
        #expect(rows[0].1 != nil)
        #expect(rows[1].0.message == "🗣 heard (me): text only")
        #expect(rows[1].1 == nil)
        #expect(rows[2].0.message.contains("stayed silent"))
        #expect(rows[3].0.message.contains("session ended by user"))
    }

    @Test func entriesDropImageWhenShotFileMissing() throws {
        let base = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: base) }
        let id = "2026-06-16_10-00-00_aaaa"
        try makeSession(base, id, lines: [
            "{\"t\":\"1\",\"m\":\"👁 looking at your screen\",\"s\":\"shot-9.jpg\"}"
        ])
        let store = SessionStore(base: base, current: nil)
        let rows = store.entries(for: try #require(store.listSessions().first))
        #expect(rows.count == 1)
        #expect(rows[0].1 == nil)
    }

    @Test func entriesUsePersistedEventTimeInsteadOfJsonlAppendOrder() throws {
        let base = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: base) }
        let id = "2026-06-16_10-00-00_aaaa"
        try makeSession(base, id, lines: [
            #"{"t":"10:00:20","m":"🗣 heard (me): \"Yep.\"","k":"heard","o":20}"#,
            #"{"t":"10:00:10","m":"🗣 heard (them): \"Did you see it?\"","k":"heard","o":10}"#,
        ])

        let store = SessionStore(base: base, current: nil)
        let session = try #require(store.listSessions().first)
        let rows = store.entries(for: session)
        #expect(rows.map(\.0.message) == [
            "🗣 heard (them): \"Did you see it?\"",
            "🗣 heard (me): \"Yep.\"",
        ])
    }

    @Test func boundedSnapshotRetainsInsertionTailBeforeOrderingByEventTime() throws {
        let base = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: base) }
        let id = "2026-06-16_10-00-00_aaaa"
        try makeSession(base, id, lines: [
            #"{"t":"10:00:30","m":"🗣 oldest insertion, late speech","k":"heard","o":30,"q":0}"#,
            #"{"t":"10:00:10","m":"🗣 middle insertion","k":"heard","o":10,"q":1}"#,
            #"{"t":"10:00:20","m":"🗣 newest insertion","k":"heard","o":20,"q":2}"#,
        ])

        let store = SessionStore(base: base, current: nil)
        let session = try #require(store.listSessions().first)
        let snapshot = store.entrySnapshot(
            for: session,
            retainingMostRecentInsertions: 2)

        #expect(snapshot.total == 3)
        #expect(snapshot.entries.map(\.0.message) == [
            "🗣 middle insertion",
            "🗣 newest insertion",
        ])
    }

    @Test func entriesPreserveFileOrderWhenChronologyMetadataIsIncomplete() throws {
        let base = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: base) }
        let id = "2026-06-16_10-00-00_aaaa"
        try makeSession(base, id, lines: [
            #"{"t":"10:00:20","m":"🗣 old row without chronology","k":"heard"}"#,
            #"{"t":"10:00:10","m":"🗣 upgraded row","k":"heard","o":10,"q":1}"#,
        ])

        let store = SessionStore(base: base, current: nil)
        let session = try #require(store.listSessions().first)
        let rows = store.entries(for: session)
        #expect(rows.map(\.0.message) == [
            "🗣 old row without chronology",
            "🗣 upgraded row",
        ])
        #expect(rows.allSatisfy { $0.0.occurredAt == nil && $0.0.insertionOrder == nil })
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
        #expect(FileManager.default.fileExists(atPath: cur.path))
        #expect(FileManager.default.fileExists(atPath: base.path))
    }

    @Test func deletionKeepsCallerProtectedAuditSession() throws {
        let base = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: base) }
        let protected = base.appendingPathComponent("2026-06-16_09-00-00_aaaa")
        let deletable = base.appendingPathComponent("2026-06-16_10-00-00_bbbb")
        let current = base.appendingPathComponent("2026-06-16_11-00-00_cccc")
        for url in [protected, deletable, current] {
            try makeSession(base, url.lastPathComponent, lines: ["{\"t\":\"1\",\"m\":\"x\"}"])
        }

        let store = SessionStore(base: base, current: current)
        store.clearHistory(preserving: [protected])

        #expect(FileManager.default.fileExists(atPath: protected.path))
        #expect(!FileManager.default.fileExists(atPath: deletable.path))
        #expect(FileManager.default.fileExists(atPath: current.path))
    }

    @Test func pruneKeepsNewestNDeletesOlderAndSparesCurrent() throws {
        let base = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: base) }
        let exists = { (id: String) in
            FileManager.default.fileExists(atPath: base.appendingPathComponent(id).path)
        }
        let ids = (0..<5).map { "2026-06-16_1\($0)-00-00_aaaa" }
        for id in ids { try makeSession(base, id, lines: ["{\"t\":\"1\",\"m\":\"🗣 heard\"}"]) }
        // Counts toward the cap even though `listSessions` hides a content-less session.
        try makeSession(base, "2026-06-16_09-00-00_zzzz", lines: [])
        try FileManager.default.createDirectory(at: base.appendingPathComponent("keepme"),
                                                withIntermediateDirectories: true)
        let cur = base.appendingPathComponent(ids[0])
        SessionStore(base: base, current: cur).pruneToMostRecent(3)

        #expect(exists(ids[4]) && exists(ids[3]) && exists(ids[2]))
        #expect(!exists(ids[1]))
        #expect(!exists("2026-06-16_09-00-00_zzzz"))
        #expect(exists(ids[0]))
        #expect(exists("keepme"))
    }

    @Test func pruneTreatsNonPositiveKeepAsOneSoCurrentSurvives() throws {
        let base = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: base) }
        try makeSession(base, "2026-06-16_10-00-00_aaaa", lines: ["{\"t\":\"1\",\"m\":\"x\"}"])
        let cur = base.appendingPathComponent("2026-06-16_10-00-00_aaaa")
        SessionStore(base: base, current: cur).pruneToMostRecent(0)
        #expect(FileManager.default.fileExists(atPath: cur.path))
    }

    @Test func pruneKeepsProtectedAuditOutsideNewestLimit() throws {
        let base = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: base) }
        let oldest = base.appendingPathComponent("2026-06-16_09-00-00_aaaa")
        let newest = base.appendingPathComponent("2026-06-16_11-00-00_cccc")
        try makeSession(base, oldest.lastPathComponent, lines: [])
        try makeSession(base, "2026-06-16_10-00-00_bbbb", lines: [])
        try makeSession(base, newest.lastPathComponent, lines: [])

        SessionStore(base: base, current: newest).pruneToMostRecent(
            1,
            preserving: [oldest])

        #expect(FileManager.default.fileExists(atPath: oldest.path))
        #expect(FileManager.default.fileExists(atPath: newest.path))
        #expect(!FileManager.default.fileExists(
            atPath: base.appendingPathComponent("2026-06-16_10-00-00_bbbb").path))
    }
}
