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
            ("10:00:00", "💬 a < b & c"),
            ("10:00:01", "🗣 heard: \"hi\""),
        ])
        #expect(html.contains("a &lt; b &amp; c"))     // content escaped
        #expect(!html.contains("a < b & c"))           // raw content not present
        #expect(html.contains("(2 lines)"))            // line count rendered
        #expect(html.contains("class=\"row say\""))    // 💬 routed to say
        #expect(html.contains("http-equiv=\"refresh\""))
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
