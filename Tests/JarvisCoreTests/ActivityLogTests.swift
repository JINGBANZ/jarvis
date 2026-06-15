import Testing
import Foundation
@testable import JarvisCore

@Suite struct ActivityLogTests {
    @Test func escapesHtmlMetacharacters() {
        #expect(ActivityLog.esc("a & b < c > d") == "a &amp; b &lt; c &gt; d")
        // & must be escaped first so we don't double-escape the entities we just inserted.
        #expect(ActivityLog.esc("<&>") == "&lt;&amp;&gt;")
    }

    @Test func cssClassKeysOnLeadingMarker() {
        #expect(ActivityLog.cssClass(for: "💬 use a hash map") == "say")
        #expect(ActivityLog.cssClass(for: "👁 looking at your screen") == "see")
        #expect(ActivityLog.cssClass(for: "🗣 heard: \"hello\"") == "hear")
        #expect(ActivityLog.cssClass(for: "🤫 quiet for 8s") == "hear")
        #expect(ActivityLog.cssClass(for: "💭 thinking…") == "think")
        #expect(ActivityLog.cssClass(for: "… held back (cooldown or rate cap)") == "think")
        #expect(ActivityLog.cssClass(for: "Jarvis realtime error event: oops") == "err")
        #expect(ActivityLog.cssClass(for: "Jarvis: coaching started.") == "")
    }

    @Test func coachingTipContainingFailedIsNotMiscolouredAsError() {
        // A spoken tip can legitimately contain the word "failed"; it must stay a 💬 say line.
        #expect(ActivityLog.cssClass(for: "💬 your test failed because the loop is off-by-one") == "say")
    }

    @Test func renderHtmlEscapesContentAndCountsLines() {
        let html = ActivityLog.renderHTML([
            .init(time: "10:00:00", message: "💬 a < b & c", imageFile: nil),
            .init(time: "10:00:01", message: "🗣 heard: \"hi\"", imageFile: nil),
        ])
        #expect(html.contains("a &lt; b &amp; c"))     // content escaped
        #expect(!html.contains("a < b & c"))           // raw content not present
        #expect(html.contains("(2 lines)"))            // line count rendered
        #expect(html.contains("class=\"row say\""))    // 💬 routed to say
        #expect(html.contains("http-equiv=\"refresh\""))
    }

    @Test func renderHtmlEmbedsScreenshotThumbnailLinkedToFullImage() {
        let html = ActivityLog.renderHTML([
            .init(time: "10:00:00", message: "👁 looking at your screen", imageFile: "shot-1.jpg"),
        ])
        #expect(html.contains("href=\"shot-1.jpg\""))       // click → full image
        #expect(html.contains("<img src=\"shot-1.jpg\""))   // thumbnail
        #expect(html.contains("target=\"_blank\""))         // opens in a new tab (survives 1s reload)
    }

    @Test func recordSavesScreenshotAsOwnerOnlyFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jarvis-test-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = ActivityLog()
        log.enable(directory: dir)
        let pixel = Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()  // stand-in JPEG bytes
        log.record("👁 looking at your screen", imageBase64: pixel)

        // record() writes asynchronously on its serial queue; drain it before asserting.
        let shot = dir.appendingPathComponent("shot-1.jpg")
        var waited = 0
        while !FileManager.default.fileExists(atPath: shot.path) && waited < 200 {
            usleep(10_000); waited += 1
        }
        #expect(FileManager.default.fileExists(atPath: shot.path))
        let perms = try FileManager.default.attributesOfItem(atPath: shot.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
        // The HTML now references the saved thumbnail.
        let html = try String(contentsOf: try #require(log.htmlURL), encoding: .utf8)
        #expect(html.contains("shot-1.jpg"))
    }

    @Test func enableWritesOwnerOnlyFileSynchronously() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jarvis-test-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = ActivityLog()                 // isolated instance, not the shared singleton
        log.enable(directory: dir)

        let url = try #require(log.htmlURL)
        #expect(FileManager.default.fileExists(atPath: url.path))  // exists synchronously after enable()
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)     // owner-only, never world-readable
    }

    @Test func recordIsNoOpWhenDisabled() {
        let log = ActivityLog()                 // never enabled, no env override
        #expect(log.htmlURL == nil)
        log.record("💬 should not crash or write anything")
        #expect(log.htmlURL == nil)
    }
}
