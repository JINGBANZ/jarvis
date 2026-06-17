import Testing
import WebKit
@testable import JarvisCore

/// Locks in the one real risk from the design review: that a real `WKWebView` loads HTML and runs
/// JS headlessly under `swift test`. If this fails to link, the run-tests.sh CLT framework flags
/// need attention; if it hangs, the harness timeout converts it to a failure.
@Suite struct HarnessSmokeTests {
    @MainActor @Test func loadsAndEvaluates() async throws {
        let h = WebViewHarness()
        try await h.load("<!doctype html><title>t</title><body><p id=\"x\">hi</p></body>")
        let value = try await h.eval("document.getElementById('x').textContent") as? String
        #expect(value == "hi")
    }
}
