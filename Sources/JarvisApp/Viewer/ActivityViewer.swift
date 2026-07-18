import AppKit
import WebKit
import JarvisCore

/// The activity viewer view: an in-app `WKWebView` that live-appends log rows pushed from
/// `ActivityLog` (no reload), shows screenshots in an in-page lightbox, and lets you browse and clear
/// past sessions via `SessionStore`. Thin by design — the rendering logic and its tests live in
/// JarvisCore (`htmlShell`/`rowScript`) and `JarvisViewerTests`. See wiki/build-and-run.md.
@MainActor
final class ActivityViewer: NSObject, WKNavigationDelegate {
    private let log: ActivityLog
    private var store: SessionStore   // rebuilt when a new session opens (see `sessionDidChange`)

    /// Builds the evaluation pipeline for the "Evaluate" button, read at click time so it always
    /// uses the current API key + model selection. Nil result ⇒ no key yet. Wired by AppDelegate;
    /// explicitly `@MainActor` because it reads AppDelegate's main-actor state (secrets, preferences).
    var makeEvaluator: (@MainActor () -> SessionEvaluator?)?

    /// Whether a coaching session is currently running (wired by AppDelegate). Read at click time —
    /// evaluation is for *finished* conversations, so the live session is off-limits until Stop:
    /// its traffic file is still being appended to, and a mid-session audit would judge half a story.
    var isCoachingRunning: (@MainActor () -> Bool)?

    private var webView: WKWebView?
    private var picker: NSPopUpButton?
    private var evaluateButton: NSButton?
    private var isEvaluating = false      // an audit is in flight; keep the button disabled meanwhile
    private var sessions: [SessionStore.Session] = []

    private var loaded = false             // page navigation finished?
    private var pending: [String] = []     // rows that arrived before didFinish (main-thread-confined)
    private var snapshotRows: [String] = [] // rows to inject once the shell has loaded
    private var pendingMeta = ""           // header text to set after the shell loads
    private var viewingCurrent = true

    // Runaway backstop only — high enough that a whole multi-hour session replays in full (cutting a
    // session's head off is worse than a big DOM; text rows are cheap and screenshots are bounded).
    private let renderCap = 10_000

    init(log: ActivityLog, store: SessionStore) {
        self.log = log
        self.store = store
    }

    // MARK: - Embeddable content view (unified Settings window)

    /// Build the viewer's content (header + WKWebView) as a standalone view for embedding in the
    /// Settings window's Activity tab. Starts live updates and loads the current session. The host
    /// window owns lifecycle; call `teardown()` when it closes. Reuses all the loading/session logic
    /// below unchanged.
    func makeContentView() -> NSView {
        // Sized to the Settings window's content region (the NSTabView resizes this to fit), not the
        // old standalone-window dimensions — so the header controls don't overlap.
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))
        content.autoresizingMask = [.width, .height]

        let header = NSVisualEffectView(frame: NSRect(x: 0, y: content.bounds.height - 44, width: content.bounds.width, height: 44))
        header.autoresizingMask = [.width, .minYMargin]
        header.material = .headerView
        header.blendingMode = .withinWindow
        header.state = .active

        let sessionLabel = NSTextField(labelWithString: "Session")
        sessionLabel.frame = NSRect(x: 14, y: 13, width: 60, height: 18)
        sessionLabel.textColor = .secondaryLabelColor
        header.addSubview(sessionLabel)

        let pop = NSPopUpButton(frame: NSRect(x: 76, y: 8, width: 240, height: 26))
        pop.target = self
        pop.action = #selector(sessionChanged)
        pop.toolTip = "Switch between this and previous sessions"
        pop.autoresizingMask = [.maxXMargin]
        header.addSubview(pop)
        self.picker = pop

        let evaluate = NSButton(title: "Evaluate", target: self, action: #selector(evaluateTapped))
        evaluate.bezelStyle = .rounded
        evaluate.frame = NSRect(x: content.bounds.width - 246, y: 8, width: 104, height: 28)
        evaluate.autoresizingMask = [.minXMargin]
        header.addSubview(evaluate)
        self.evaluateButton = evaluate

        let clear = NSButton(title: "Clear history", target: self, action: #selector(clearHistoryTapped))
        clear.bezelStyle = .rounded
        clear.toolTip = "Delete all previous sessions (keeps the current one)"
        clear.frame = NSRect(x: content.bounds.width - 134, y: 8, width: 120, height: 28)
        clear.autoresizingMask = [.minXMargin]
        header.addSubview(clear)

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: content.bounds.width, height: content.bounds.height - 44))
        wv.autoresizingMask = [.width, .height]
        wv.navigationDelegate = self

        content.addSubview(wv)
        content.addSubview(header)
        self.webView = wv

        populatePicker()
        loadCurrent()
        return content
    }

    /// Stop receiving live rows and release the WebView. Called by the host when the window closes.
    func teardown() {
        log.detach()
        webView = nil
        picker = nil
        evaluateButton = nil
        loaded = false
        pending = []
        snapshotRows = []
    }

    /// A new coaching session opened (a Start rotated the session dir). Re-point the history browser at
    /// the new current dir; if the viewer is on-screen, refresh the picker and re-attach to the fresh
    /// live session. `ActivityLog.enable` dropped the previous observer, so without this an open viewer
    /// would freeze on the old session's rows. No-op when not embedded — the next open reads it fresh.
    func sessionDidChange(base: URL, current: URL?) {
        store = SessionStore(base: base, current: current)
        guard webView != nil else { return }
        populatePicker()
        loadCurrent()
    }

    // MARK: - Session list

    private func populatePicker() {
        sessions = store.listSessions()
        picker?.removeAllItems()
        for s in sessions {
            picker?.addItem(withTitle: s.isCurrent ? "\(s.label) (current)" : s.label)
        }
        // Default-select the current session if present.
        if let idx = sessions.firstIndex(where: { $0.isCurrent }) {
            picker?.selectItem(at: idx)
        }
        refreshEvaluateButtonState()
    }

    @objc private func sessionChanged() {
        guard let idx = picker?.indexOfSelectedItem, sessions.indices.contains(idx) else { return }
        let s = sessions[idx]
        if s.isCurrent { loadCurrent() } else { loadPast(s) }
        refreshEvaluateButtonState()
    }

    /// Coaching started or stopped (AppDelegate calls this from Start/Stop): the live session just
    /// became off-limits for evaluation, or the now-stopped one became evaluable.
    func coachingStateDidChange() {
        refreshEvaluateButtonState()
    }

    /// Evaluate is enabled only for a *finished* conversation: any past session, or the current one
    /// once coaching is stopped. A live session's traffic file is still being appended to, so an
    /// audit of it would judge half a story. A session that already has a persisted report flips the
    /// button to "Open report" instead — reopening the saved audit is free and always safe, so it
    /// stays enabled regardless of coaching state. Owns the title too: `isEvaluating` survives a
    /// Settings close/reopen (the viewer outlives its content view), so a rebuilt button mid-audit
    /// correctly shows "Evaluating…" disabled instead of inviting a duplicate audit.
    private func refreshEvaluateButtonState() {
        guard let button = evaluateButton else { return }
        if isEvaluating {
            button.title = "Evaluating…"
            button.isEnabled = false
            return
        }
        guard let idx = picker?.indexOfSelectedItem, sessions.indices.contains(idx) else {
            button.title = "Evaluate"
            button.isEnabled = false
            return
        }
        let session = sessions[idx]
        if SessionEvaluator.savedReport(in: session.url) != nil {
            button.title = "Open report"
            button.toolTip = "Open this session's evaluation report in your browser"
            button.isEnabled = true
        } else {
            button.title = "Evaluate"
            button.toolTip = "Send this session's recorded LLM traffic to the brain model for a context-engineering audit (stopped sessions only)"
            button.isEnabled = !(session.isCurrent && (isCoachingRunning?() ?? false))
        }
    }

    // MARK: - Loading

    private func loadCurrent() {
        viewingCurrent = true
        let snap = log.attach { [weak self] js in
            DispatchQueue.main.async { self?.onAppend(js) }
        }
        beginLoad(shell: snap.shellHTML, rows: snap.rows, shown: snap.shown, total: snap.total)
    }

    private func loadPast(_ session: SessionStore.Session) {
        viewingCurrent = false
        log.detach()   // a past session is static; stop receiving live rows
        let all = store.entries(for: session)
        let shown = all.suffix(renderCap)
        let rows = shown.map { entry, data in
            ActivityLog.rowScript(time: entry.time, message: entry.message,
                                  imageBase64: data?.base64EncodedString())
        }
        beginLoad(shell: ActivityLog.htmlShell(), rows: rows, shown: rows.count, total: all.count)
    }

    private func beginLoad(shell: String, rows: [String], shown: Int, total: Int) {
        loaded = false
        pending = []
        snapshotRows = rows
        pendingMeta = total > shown ? "showing last \(shown) of \(total)" : "\(total) lines"
        webView?.loadHTMLString(shell, baseURL: nil)
    }

    /// A live row arrived (main thread). Inject it now if the page is ready, else buffer it.
    private func onAppend(_ js: String) {
        guard viewingCurrent else { return }   // ignore stray live rows while viewing a past session
        if loaded {
            webView?.evaluateJavaScript(js, completionHandler: nil)
        } else {
            pending.append(js)
        }
    }

    // MARK: - WKNavigationDelegate

    /// Deny every navigation except the initial in-memory load — a pushed `data:` image or any link
    /// click must not be able to navigate the WebView away (defense-in-depth for screen-derived data).
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url?.absoluteString
        decisionHandler(url == nil || url == "about:blank" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        // Snapshot rows first, then anything buffered while loading — both in FIFO order.
        for js in snapshotRows { webView.evaluateJavaScript(js, completionHandler: nil) }
        for js in pending { webView.evaluateJavaScript(js, completionHandler: nil) }
        snapshotRows = []
        pending = []
        webView.evaluateJavaScript("setMeta(\(jsString(pendingMeta)));", completionHandler: nil)
    }

    // MARK: - Session evaluation

    /// One click: send the selected session's recorded brain traffic to the evaluation model and
    /// show (and persist) the resulting audit report. A session that was already evaluated just
    /// reopens its saved report — no re-billing. Only *stopped* conversations qualify for a fresh
    /// audit: any past session, or the current one once coaching is stopped. The button is already
    /// disabled for the live session (`refreshEvaluateButtonState`); the guard here is the
    /// race-proof backstop for a click that lands exactly as a Start flips the state.
    @objc private func evaluateTapped() {
        guard let idx = picker?.indexOfSelectedItem, sessions.indices.contains(idx) else { return }
        let session = sessions[idx]
        if let report = SessionEvaluator.savedReport(in: session.url) {
            openReport(report, for: session)
            return
        }
        if session.isCurrent, isCoachingRunning?() == true {
            info("Session still running",
                 "Evaluation works on a finished conversation. Stop Jarvis first, then evaluate this session.")
            return
        }
        guard SessionEvaluator.hasTraffic(in: session.url) else {
            info("Nothing to evaluate",
                 "This session has no recorded LLM traffic. Traffic is captured from the first coaching turn onward.")
            return
        }
        guard let evaluator = makeEvaluator?() else {
            info("No API key", "Paste your API key in Settings first — the evaluation runs on the same key.")
            return
        }
        isEvaluating = true
        refreshEvaluateButtonState()
        Task { [weak self] in
            defer {
                self?.isEvaluating = false
                self?.refreshEvaluateButtonState()
            }
            do {
                let report = try await evaluator.evaluate(sessionDir: session.url)
                self?.openReport(report, for: session)
            } catch {
                self?.info("Evaluation failed", error.localizedDescription)
            }
        }
    }

    /// Open the report in the user's browser: render the markdown to `eval-report.html` beside it
    /// (regenerated every open, so it never goes stale after a dev-side agentic re-audit rewrites
    /// the `.md`) and hand the page to the default browser. The page carries a "Copy as Markdown"
    /// button so the raw report can be pasted into an agent chat to work on the findings.
    private func openReport(_ report: String, for session: SessionStore.Session) {
        do {
            let url = try EvalReportPage.write(markdown: report, in: session.url,
                                               title: "Session evaluation — \(session.label)")
            NSWorkspace.shared.open(url)
        } catch {
            info("Couldn't write the report page", error.localizedDescription)
        }
    }

    private func info(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: - Clear history

    @objc private func clearHistoryTapped() {
        let alert = NSAlert()
        alert.messageText = "Clear session history?"
        alert.informativeText = "This permanently deletes all previous sessions (logs and screenshots). The current session is kept."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.clearHistory()
        populatePicker()
        loadCurrent()   // the viewed session may be gone; fall back to the live one
    }

    /// Encode a Swift string as a JS string literal (for `setMeta`).
    private func jsString(_ s: String) -> String {
        (try? String(data: JSONEncoder().encode(s), encoding: .utf8)) ?? "\"\""
    }
}
