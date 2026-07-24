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

    /// Whether a coaching session is currently running (wired by AppDelegate). Report opening is an
    /// explicit browser presentation, so it remains disabled for the full coaching lifecycle.
    var isCoachingRunning: (@MainActor () -> Bool)?

    private var webView: WKWebView?
    private var picker: NSPopUpButton?
    private var copySessionIDButton: NSButton?
    private var reportButton: NSButton?
    private var clearHistoryButton: NSButton?
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

        let headerHeight: CGFloat = 44
        let header = NSVisualEffectView(frame: NSRect(x: 0,
                                                      y: content.bounds.height - headerHeight,
                                                      width: content.bounds.width,
                                                      height: headerHeight))
        header.autoresizingMask = [.width, .minYMargin]
        header.material = .headerView
        header.blendingMode = .withinWindow
        header.state = .active

        let sessionLabel = NSTextField(labelWithString: "Session")
        sessionLabel.translatesAutoresizingMaskIntoConstraints = false
        sessionLabel.textColor = .secondaryLabelColor
        header.addSubview(sessionLabel)

        let pop = NSPopUpButton(frame: .zero)
        pop.translatesAutoresizingMaskIntoConstraints = false
        pop.target = self
        pop.action = #selector(sessionChanged)
        pop.toolTip = "Switch between this and previous sessions"
        pop.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.addSubview(pop)
        self.picker = pop

        let copyID = NSButton(title: "Copy ID", target: self, action: #selector(copySessionIDTapped))
        copyID.translatesAutoresizingMaskIntoConstraints = false
        copyID.bezelStyle = .rounded
        copyID.toolTip = "Copy the exact session ID"
        header.addSubview(copyID)
        self.copySessionIDButton = copyID

        let report = NSButton(title: "Open report", target: self, action: #selector(openReportTapped))
        report.translatesAutoresizingMaskIntoConstraints = false
        report.bezelStyle = .rounded
        header.addSubview(report)
        self.reportButton = report

        let clear = NSButton(title: "Clear history", target: self, action: #selector(clearHistoryTapped))
        clear.translatesAutoresizingMaskIntoConstraints = false
        clear.bezelStyle = .rounded
        clear.toolTip = "Delete all previous sessions (keeps the current one)"
        header.addSubview(clear)
        self.clearHistoryButton = clear

        let preferredPickerWidth = pop.widthAnchor.constraint(equalToConstant: 230)
        // Prefer the full picker width, but let window resizing compress it.
        preferredPickerWidth.priority = .init(rawValue: 490)
        NSLayoutConstraint.activate([
            sessionLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            sessionLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            pop.leadingAnchor.constraint(equalTo: sessionLabel.trailingAnchor, constant: 2),
            pop.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            pop.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            preferredPickerWidth,
            copyID.leadingAnchor.constraint(equalTo: pop.trailingAnchor, constant: 8),
            copyID.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            copyID.widthAnchor.constraint(equalToConstant: 78),
            copyID.trailingAnchor.constraint(lessThanOrEqualTo: report.leadingAnchor, constant: -8),
            report.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            report.widthAnchor.constraint(equalToConstant: 104),
            report.trailingAnchor.constraint(equalTo: clear.leadingAnchor, constant: -8),
            clear.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            clear.widthAnchor.constraint(equalToConstant: 120),
            clear.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
        ])

        let wv = WKWebView(frame: NSRect(x: 0, y: 0,
                                        width: content.bounds.width,
                                        height: content.bounds.height - headerHeight))
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
        copySessionIDButton = nil
        reportButton = nil
        clearHistoryButton = nil
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
        refreshCopySessionIDButtonState()
        refreshReportButtonState()
    }

    @objc private func sessionChanged() {
        guard let idx = picker?.indexOfSelectedItem, sessions.indices.contains(idx) else { return }
        let s = sessions[idx]
        if s.isCurrent { loadCurrent() } else { loadPast(s) }
        refreshCopySessionIDButtonState()
        refreshReportButtonState()
    }

    private func refreshCopySessionIDButtonState() {
        guard let idx = picker?.indexOfSelectedItem, sessions.indices.contains(idx) else {
            copySessionIDButton?.isEnabled = false
            return
        }
        copySessionIDButton?.isEnabled = true
    }

    @objc private func copySessionIDTapped() {
        guard let idx = picker?.indexOfSelectedItem, sessions.indices.contains(idx) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sessions[idx].id, forType: .string)
    }

    /// Coaching started or stopped (AppDelegate calls this from Start/Stop): explicit browser
    /// presentation is suppressed until the full coaching lifecycle has ended.
    func coachingStateDidChange() {
        refreshReportButtonState()
    }

    /// A dev-side evaluator may have written a report while Settings remained open on another tab.
    /// Recheck the selected session when Activity becomes visible again.
    func didBecomeActive() {
        refreshReportButtonState()
    }

    /// Open report and Clear stay disabled for the entire coaching lifecycle. The report button is
    /// discover-only: the sole evaluator is the dev-side agentic workflow, and Activity opens its
    /// saved result without launching an evaluator from the app.
    private func refreshReportButtonState() {
        let coachingRunning = isCoachingRunning?() == true
        clearHistoryButton?.isEnabled = !coachingRunning
        guard let button = reportButton else { return }
        button.title = "Open report"
        guard let idx = picker?.indexOfSelectedItem, sessions.indices.contains(idx) else {
            button.toolTip = "No session selected"
            button.isEnabled = false
            return
        }
        let session = sessions[idx]
        if coachingRunning {
            button.toolTip = "Stop Jarvis before opening a report"
            button.isEnabled = false
            return
        }
        if AgenticEvaluation.savedReport(in: session.url) != nil {
            button.toolTip = "Open this session's evaluation report in your browser"
            button.isEnabled = true
        } else {
            button.toolTip = "No agentic evaluation report exists for this session"
            button.isEnabled = false
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

    // MARK: - Session report

    /// Open the selected session's saved agentic report. Evaluation itself is intentionally
    /// dev-side (`scripts/eval-session.sh`), where an agent can inspect the repo and complete session
    /// directory instead of receiving a reduced prompt from the app.
    @objc private func openReportTapped() {
        guard isCoachingRunning?() != true else {
            jlog("Jarvis: suppressed Activity report presentation while coaching is running.")
            return
        }
        guard let idx = picker?.indexOfSelectedItem, sessions.indices.contains(idx) else { return }
        let session = sessions[idx]
        guard let report = AgenticEvaluation.savedReport(in: session.url) else { return }
        openReport(report, for: session)
    }

    /// Open the report in the user's browser: render the markdown to `eval-report.html` beside it
    /// (regenerated every open, so it never goes stale after a dev-side agentic re-audit rewrites
    /// the `.md`) and hand the page to the default browser. The page carries a "Copy as Markdown"
    /// button so the raw report can be pasted into an agent chat to work on the findings.
    private func openReport(_ report: String, for session: SessionStore.Session) {
        guard isCoachingRunning?() != true else {
            jlog("Jarvis: suppressed Activity report presentation while coaching is running.")
            return
        }
        do {
            let url = try EvalReportPage.write(markdown: report, in: session.url,
                                               title: "Session evaluation — \(session.label)")
            NSWorkspace.shared.open(url) // ghost-mode-allowed: guarded explicit Activity action
        } catch {
            info("Couldn't write the report page", error.localizedDescription)
        }
    }

    private func info(_ title: String, _ message: String) {
        guard isCoachingRunning?() != true else {
            jlog("Jarvis: suppressed Activity alert while coaching is running — \(title): \(message)")
            return
        }
        let alert = NSAlert() // ghost-mode-allowed: guarded explicit Activity action
        alert.messageText = title
        alert.informativeText = message
        alert.runModal() // ghost-mode-allowed: guarded explicit Activity action
    }

    // MARK: - Clear history

    @objc private func clearHistoryTapped() {
        guard isCoachingRunning?() != true else {
            jlog("Jarvis: suppressed Clear history confirmation while coaching is running.")
            return
        }
        let alert = NSAlert() // ghost-mode-allowed: guarded explicit Activity action
        alert.messageText = "Clear session history?"
        alert.informativeText = "This permanently deletes all previous sessions (logs and screenshots). The current session is kept."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return } // ghost-mode-allowed: guarded explicit Activity action
        store.clearHistory()
        populatePicker()
        loadCurrent()   // the viewed session may be gone; fall back to the live one
    }

    /// Encode a Swift string as a JS string literal (for `setMeta`).
    private func jsString(_ s: String) -> String {
        (try? String(data: JSONEncoder().encode(s), encoding: .utf8)) ?? "\"\""
    }
}
