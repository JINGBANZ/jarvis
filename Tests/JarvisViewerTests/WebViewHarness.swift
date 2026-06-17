import Foundation
import WebKit

/// Drives a real `WKWebView` headlessly inside `swift test`: loads HTML and awaits the navigation,
/// then runs JS via `evaluateJavaScript`. A per-load timeout + a single-resume guard mean a stuck or
/// failed load *fails the test* instead of hanging CI. swift-testing's runner pumps the main run
/// loop, so no `NSApplication` is needed (verified on Command-Line-Tools-only machines).
@MainActor
final class WebViewHarness: NSObject, WKNavigationDelegate {
    let webView = WKWebView(frame: .init(x: 0, y: 0, width: 480, height: 320))
    private var cont: CheckedContinuation<Void, Error>?
    private var resumed = false

    override init() {
        super.init()
        webView.navigationDelegate = self
    }

    enum HarnessError: Error { case timeout }

    /// Load `html` and await `didFinish` (or fail on error / 5s timeout).
    func load(_ html: String) async throws {
        resumed = false
        let timeout = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self.resume(.failure(HarnessError.timeout))
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.cont = c
            self.webView.loadHTMLString(html, baseURL: nil)
        }
    }

    @discardableResult
    func eval(_ js: String) async throws -> Any? {
        try await webView.evaluateJavaScript(js)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { resume(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { resume(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { resume(.failure(error)) }

    private func resume(_ result: Result<Void, Error>) {
        guard !resumed else { return }
        resumed = true
        switch result {
        case .success: cont?.resume()
        case .failure(let e): cont?.resume(throwing: e)
        }
        cont = nil
    }
}
