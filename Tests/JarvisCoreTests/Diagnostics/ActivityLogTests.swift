import Testing
import Foundation
@testable import JarvisCore

@Suite struct ActivityLogTests {
    @Test func cssClassKeysOnLeadingMarker() {
        #expect(ActivityLog.cssClass(for: "💬 use a hash map") == "say")
        #expect(ActivityLog.cssClass(for: "👁 looking at your screen") == "see")
        #expect(ActivityLog.cssClass(for: "🗣 heard: \"hello\"") == "hear")
        #expect(ActivityLog.cssClass(for: "🤫 quiet for 8s") == "hear")
        #expect(ActivityLog.cssClass(for: "💭 thinking…") == "think")
        #expect(ActivityLog.cssClass(for: "… nothing useful to add, staying silent") == "think")
        #expect(ActivityLog.cssClass(for: "⏹ coaching stopped — Claude Code couldn't respond") == "think")
        #expect(ActivityLog.cssClass(for: "Jarvis realtime error event: oops") == "err")
        #expect(ActivityLog.cssClass(for: "Jarvis: coaching started.") == "")
        // A spoken tip can legitimately contain "failed"; it must stay a 💬 say line.
        #expect(ActivityLog.cssClass(for: "💬 your test failed because the loop is off-by-one") == "say")
    }

    @Test func rowScriptEncodesTextSafelyAndOmitsImageWhenNil() throws {
        let js = ActivityLog.rowScript(time: "10:00:00", message: "a < b & \"c\" </script>", imageBase64: nil)
        #expect(js.hasPrefix("appendRow("))
        #expect(js.hasSuffix(");"))
        #expect(!js.contains("data:image"))            // no image payload when nil
        // The object inside appendRow(...) must be valid JSON with the raw (JSON-escaped) message.
        let inner = String(js.dropFirst("appendRow(".count).dropLast(");".count))
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(inner.utf8)) as? [String: Any])
        #expect(obj["message"] as? String == "a < b & \"c\" </script>")
        #expect(obj["time"] as? String == "10:00:00")
        #expect(obj["cls"] as? String == "")           // no leading marker
        #expect(obj["img"] == nil)                      // key omitted, not null
    }

    @Test func rowScriptBuildsDataURIWhenImagePresent() {
        let js = ActivityLog.rowScript(time: "10:00:01", message: "👁 looked", imageBase64: "QUJD")
        #expect(js.contains("data:image/jpeg;base64,QUJD"))
        #expect(js.contains("\"cls\":\"see\"") || js.contains("\"cls\": \"see\""))
    }

    @Test func recordPersistsJsonlAndShotThenNotifiesObserver() throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = ActivityLog(); log.enable(directory: dir)
        var pushed: [String] = []
        let snap = log.attach { pushed.append($0) }
        #expect(snap.rows.isEmpty)                       // empty session
        #expect(snap.total == 0)
        let pixel = Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()
        log.record(.screenViewed(imageBase64JPEG: pixel))
        log.record(.tip(lines: ["tip"]))
        _ = log.attach { _ in }                          // sync barrier: drains the serial queue

        let jsonl = try String(contentsOf: dir.appendingPathComponent("jarvis-activity.jsonl"), encoding: .utf8)
        #expect(jsonl.split(separator: "\n").count == 2)
        let shot = dir.appendingPathComponent("shot-1.jpg")
        #expect(FileManager.default.fileExists(atPath: shot.path))
        let perms = try FileManager.default.attributesOfItem(atPath: shot.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
        #expect(pushed.count == 2)
        #expect(pushed[0].contains("data:image/jpeg;base64,"))
        #expect(pushed[1].contains("appendRow("))
    }

    @Test func attachSnapshotReplaysExistingEntriesWithImageBytes() throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = ActivityLog(); log.enable(directory: dir)
        let pixel = Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()
        log.record(.screenViewed(imageBase64JPEG: pixel))
        log.record(.tip(lines: ["tip"]))
        let snap = log.attach { _ in }                   // late attach: snapshot must contain prior rows
        #expect(snap.rows.count == 2)
        #expect(snap.shown == 2)
        #expect(snap.total == 2)
        #expect(snap.rows[0].contains("data:image/jpeg;base64,"))   // image bytes re-read from disk
        #expect(snap.shellHTML.contains("appendRow"))               // shell carries the JS
    }

    @Test func enableCreatesJsonlImmediately() throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = ActivityLog(); log.enable(directory: dir)
        _ = log.attach { _ in }
        let url = dir.appendingPathComponent("jarvis-activity.jsonl")
        #expect(FileManager.default.fileExists(atPath: url.path))
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
    }

    @Test func recordIsNoOpWhenDisabled() {
        let log = ActivityLog()                          // never enabled
        log.record(.tip(lines: ["should not crash or write anything"]))
        let snap = log.attach { _ in }
        #expect(snap.total == 0)
        #expect(snap.rows.isEmpty)
    }

    @Test func eventFormattingKeepsDiagnosticDetailsOut() throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = ActivityLog(); log.enable(directory: dir)
        log.record(.heard(speaker: .them, text: "How would you optimize it?"))
        _ = log.attach { _ in }

        let jsonl = try String(contentsOf: dir.appendingPathComponent("jarvis-activity.jsonl"), encoding: .utf8)
        #expect(jsonl.contains(#"heard (them): \"How would you optimize it?\""#))
        #expect(!jsonl.contains("item"))
        #expect(!jsonl.contains("recovered"))
    }

    @Test func coachingStoppedPersistsOnlyADiscreetHumanFacingNotice() throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = ActivityLog(); log.enable(directory: dir)
        log.record(.coachingStopped(provider: .claudeCode))
        let snapshot = log.attach { _ in }

        let row = try #require(snapshot.rows.first)
        #expect(row.contains("coaching stopped"))
        #expect(row.contains("Claude Code"))
        #expect(row.contains("Settings"))
        #expect(!row.contains("OAuth"))
        #expect(ActivityLog.isHumanFacing(
            message: "⏹ coaching stopped — Claude Code couldn't respond; check Settings → Brain",
            imageFile: nil
        ))
    }

    /// Shared temp-dir helper (also used by SessionStoreTests). Owner-only dir, like the real app.
    static func tmp() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jarvis-test-\(ProcessInfo.processInfo.globallyUniqueString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return d
    }
}
