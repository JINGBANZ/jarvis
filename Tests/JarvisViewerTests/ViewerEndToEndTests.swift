import Testing
import WebKit
@testable import JarvisCore

/// End-to-end: a real `WKWebView` loads the shipped page shell and runs the *actual shipped JS*
/// (`appendRow`, the lightbox handlers) driven through `ActivityLog`'s real `rowScript` output —
/// the exact code path the production viewer uses.
// WKWebView instances share AppKit's main loop and WebKit process resources. A single viewer case at
// a time avoids starving unrelated main-actor timer tests while the rest of the suite stays parallel.
@Suite(.serialized) struct ViewerEndToEndTests {
    @MainActor @Test func appendRowRendersTextSafely() async throws {
        let h = WebViewHarness()
        try await h.load(ActivityLog.htmlShell())
        try await h.eval(ActivityLog.rowScript(time: "10:00", message: "<script>x</script> & \"q\"", imageBase64: nil))
        let txt = try await h.eval("document.querySelector('.row .m').textContent") as? String
        #expect(txt == "<script>x</script> & \"q\"")          // shown verbatim as text
        let injected = try await h.eval("document.querySelectorAll('#log script').length") as? Int
        #expect(injected == 0)                                  // nothing executed/injected
    }

    @MainActor @Test func appendRowRoutesColourClass() async throws {
        let h = WebViewHarness()
        try await h.load(ActivityLog.htmlShell())
        try await h.eval(ActivityLog.rowScript(time: "10:00", message: "💬 tip", imageBase64: nil))
        let cls = try await h.eval("document.querySelector('.row').className") as? String
        #expect(cls?.contains("say") == true)
    }

    @MainActor @Test func coreInsertionIndexPlacesLateRow() async throws {
        let h = WebViewHarness()
        try await h.load(ActivityLog.htmlShell())
        try await h.eval(ActivityLog.rowScript(
            time: "10:00:20",
            message: "🗣 heard (me): Yep.",
            imageBase64: nil))
        try await h.eval(ActivityLog.rowScript(
            time: "10:00:10",
            message: "🗣 heard (them): Did you see it?",
            imageBase64: nil,
            insertionIndex: 0))

        let messages = try await h.eval(
            "Array.from(document.querySelectorAll('#log .m')).map(x=>x.textContent).join('|')"
        ) as? String
        #expect(messages == "🗣 heard (them): Did you see it?|🗣 heard (me): Yep.")
    }

    @MainActor @Test func liveCapRemovalKeepsFollowingInsertionIndexAligned() async throws {
        let h = WebViewHarness()
        try await h.load(ActivityLog.htmlShell())
        try await h.eval(ActivityLog.rowScript(
            time: "1", message: "old", imageBase64: nil, insertionOrder: 0))
        try await h.eval(ActivityLog.rowScript(
            time: "2", message: "kept", imageBase64: nil, insertionOrder: 1))
        try await h.eval(ActivityLog.rowScript(
            time: "3", message: "new", imageBase64: nil,
            insertionIndex: 1,
            insertionOrder: 2,
            removedInsertionOrders: [0]))

        let messages = try await h.eval(
            "Array.from(document.querySelectorAll('#log .m')).map(x=>x.textContent).join('|')"
        ) as? String
        let identities = try await h.eval(
            "Array.from(document.querySelectorAll('#log .row')).map(x=>x.dataset.insertionOrder).join('|')"
        ) as? String
        #expect(messages == "kept|new")
        #expect(identities == "1|2")
    }

    @MainActor @Test func activityFeedUsesAdaptiveSettingsRowLayout() async throws {
        let h = WebViewHarness()
        try await h.load(ActivityLog.htmlShell())
        try await h.eval(ActivityLog.rowScript(time: "10:00", message: "💬 tip", imageBase64: nil))

        let colorScheme = try await h.eval(
            "getComputedStyle(document.documentElement).colorScheme"
        ) as? String
        let display = try await h.eval(
            "getComputedStyle(document.querySelector('.row')).display"
        ) as? String
        let border = try await h.eval(
            "getComputedStyle(document.querySelector('.row')).borderBottomStyle"
        ) as? String
        #expect(colorScheme?.contains("light") == true)
        #expect(colorScheme?.contains("dark") == true)
        #expect(display == "grid")
        #expect(border == "solid")
    }

    @MainActor @Test func readinessBadgeIsLivePageStateNotAnActivityRow() async throws {
        let h = WebViewHarness()
        try await h.load(ActivityLog.htmlShell())
        try await h.eval("setReadiness('<Active & listening>','active'); null")

        let text = try await h.eval(
            "document.getElementById('readiness').textContent"
        ) as? String
        let state = try await h.eval(
            "document.getElementById('readiness').dataset.state"
        ) as? String
        let rows = try await h.eval("document.querySelectorAll('#log .row').length") as? Int
        #expect(text == "<Active & listening>")
        #expect(state == "active")
        #expect(rows == 0)
    }

    @MainActor @Test func thumbnailClickOpensLightboxAndEscapeCloses() async throws {
        let h = WebViewHarness()
        try await h.load(ActivityLog.htmlShell())
        try await h.eval(ActivityLog.rowScript(time: "10:00", message: "👁 looked", imageBase64: "QUJD"))
        let imgSrc = try await h.eval("document.querySelector('a.shot img').src") as? String
        #expect(imgSrc?.contains("data:image/jpeg;base64,QUJD") == true)

        try await h.eval("document.querySelector('a.shot').click(); null")
        let openSrc = try await h.eval(
            "document.getElementById('lightbox').classList.contains('open') ? document.getElementById('lightbox-img').src : ''"
        ) as? String
        #expect(openSrc?.contains("QUJD") == true)              // modal open, showing the same image

        try await h.eval("document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape'})); null")
        let stillOpen = try await h.eval("document.getElementById('lightbox').classList.contains('open')") as? Bool
        #expect(stillOpen == false)                             // Escape closes it
    }

    @MainActor @Test func backdropClickClosesLightbox() async throws {
        let h = WebViewHarness()
        try await h.load(ActivityLog.htmlShell())
        try await h.eval(ActivityLog.rowScript(time: "10:00", message: "👁", imageBase64: "QUJD"))
        try await h.eval("document.querySelector('a.shot').click(); null")
        try await h.eval("document.getElementById('lightbox').click(); null")
        let open = try await h.eval("document.getElementById('lightbox').classList.contains('open')") as? Bool
        #expect(open == false)
    }

    @MainActor @Test func snapshotReplayRendersAllRowsAndClearRowsEmpties() async throws {
        let h = WebViewHarness()
        try await h.load(ActivityLog.htmlShell())
        for r in [ActivityLog.rowScript(time: "1", message: "a", imageBase64: nil),
                  ActivityLog.rowScript(time: "2", message: "b", imageBase64: nil),
                  ActivityLog.rowScript(time: "3", message: "c", imageBase64: nil)] {
            try await h.eval(r)
        }
        let n = try await h.eval("document.querySelectorAll('#log .row').length") as? Int
        #expect(n == 3)
        try await h.eval("clearRows(); null")
        let after = try await h.eval("document.querySelectorAll('#log .row').length") as? Int
        #expect(after == 0)                                     // session-switch path reuses the page
    }

    /// A session that lost evidence must not present an apparently complete story.
    @MainActor @Test func incompleteEvidenceShowsTheFixedNotice() async throws {
        let h = WebViewHarness()
        try await h.load(ActivityLog.htmlShell())
        try await h.eval(ActivityLog.rowScript(time: "10:00", message: "💬 tip", imageBase64: nil))
        try await h.eval(ActivityLog.evidenceScript(isComplete: false))

        let text = try await h.eval(
            "document.getElementById('evidence').textContent") as? String
        let detail = try await h.eval("document.getElementById('evidence').title") as? String
        #expect(text == ActivityLog.incompleteEvidenceNotice)
        #expect(detail == ActivityLog.incompleteEvidenceDetail)
        // The notice is a property of the record, not an Activity row.
        let rows = try await h.eval("document.querySelectorAll('#log .row').length") as? Int
        #expect(rows == 1)

        // Fixed and human-safe: it names no provider, error, timing, retry, or lifecycle detail.
        let notice = ActivityLog.incompleteEvidenceNotice + " " + ActivityLog.incompleteEvidenceDetail
        for forbidden in [
            "error", "failed", "retry", "timeout", "queue", "overflow", "write", "worker",
            "partial", "http", "ms",
        ] {
            #expect(!notice.lowercased().contains(forbidden), "notice leaked \(forbidden)")
        }
    }

    /// A complete session shows nothing at all — an empty badge collapses out of the header.
    @MainActor @Test func completeEvidenceShowsNoNotice() async throws {
        let h = WebViewHarness()
        try await h.load(ActivityLog.htmlShell())
        try await h.eval(ActivityLog.evidenceScript(isComplete: true))

        let text = try await h.eval(
            "document.getElementById('evidence').textContent") as? String
        #expect(text == "")
        let display = try await h.eval(
            "getComputedStyle(document.getElementById('evidence')).display") as? String
        #expect(display == "none")
    }

    /// The notice clears when the viewer switches from an incomplete session to a complete one, so
    /// a stale badge cannot follow the reader into another session's history.
    @MainActor @Test func switchingToACompleteSessionClearsTheNotice() async throws {
        let h = WebViewHarness()
        try await h.load(ActivityLog.htmlShell())
        try await h.eval(ActivityLog.evidenceScript(isComplete: false))
        try await h.eval(ActivityLog.evidenceScript(isComplete: true))
        let text = try await h.eval(
            "document.getElementById('evidence').textContent") as? String
        #expect(text == "")
    }
}
