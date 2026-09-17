import Testing
import WebKit
@testable import JarvisCore

/// A link failure here points at the CLT framework flags in `scripts/run-tests.sh`.
@Suite struct HarnessSmokeTests {
    @MainActor @Test func loadsAndEvaluates() async throws {
        let h = WebViewHarness()
        try await h.load("<!doctype html><title>t</title><body><p id=\"x\">hi</p></body>")
        let value = try await h.eval("document.getElementById('x').textContent") as? String
        #expect(value == "hi")
    }
}
