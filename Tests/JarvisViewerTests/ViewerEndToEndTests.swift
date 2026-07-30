import Testing
import WebKit
@testable import JarvisCore

/// End-to-end: a real `WKWebView` loads the shipped page shell and runs the *actual shipped JS*
/// (`appendRow`, the lightbox handlers) driven through `ActivityLog`'s real `rowScript` output —
/// the exact code path the production viewer uses.
@Suite struct ViewerEndToEndTests {
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
}
