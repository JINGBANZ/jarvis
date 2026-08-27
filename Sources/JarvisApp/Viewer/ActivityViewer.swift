import AppKit
import WebKit
import JarvisCore
import JarvisEvaluation

/// The activity viewer view: an in-app `WKWebView` that live-appends log rows pushed from
/// `ActivityLog` (no reload), shows screenshots in an in-page lightbox, and lets you browse and clear
/// past sessions via `SessionStore`. Its compact header badge renders the same live
/// `JarvisReadiness.Status` as the menu without appending an Activity row. Thin by design — the
/// rendering logic and its tests live in JarvisCore (`htmlShell`/`rowScript`) and
/// `JarvisViewerTests`. See wiki/build-and-run.md.
@MainActor
final class ActivityViewer: NSObject, WKNavigationDelegate {
    private let log: ActivityLog
    private var store: SessionStore   // rebuilt when a new session opens (see `sessionDidChange`)

    /// Builds the sole agentic evaluation pipeline at click time so it uses the current provider
    /// selection and source checkout. Nil means this app instance cannot locate its checkout.
    var makeEvaluator: (@MainActor () -> AgenticEvaluator?)?

    /// Whether a coaching session is currently running (wired by AppDelegate). Evaluation and report
    /// opening are explicit user actions, but their presentation stays outside the ghost lifecycle.
    var isCoachingRunning: (@MainActor () -> Bool)?
    /// Per-session persistence gate used only while a normal Stop close is still running.
    var isSessionAuditClosed: (@MainActor (URL) -> Bool)?
    /// Directories still owned by background close work must survive Clear history.
    var protectedSessionDirectories: (@MainActor () -> Set<URL>)?

    private var webView: WKWebView?
    private var picker: NSPopUpButton?
    private var copySessionIDButton: NSButton?
    private var evaluateButton: NSButton?
    private var clearHistoryButton: NSButton?
    /// Survives a Settings close/reopen because the viewer itself lives for the whole app run.
    private var isEvaluating = false
    /// Retained so Quit can cancel the direct CLI child instead of leaving an orphaned paid run.
    private var evaluationTask: Task<Void, Never>?
    private var sessions: [SessionStore.Session] = []

    private var loaded = false             // page navigation finished?
    private var pending: [String] = []     // rows that arrived before didFinish (main-thread-confined)
    private var snapshotRows: [String] = [] // rows to inject once the shell has loaded
    private var pendingMeta = ""           // header text to set after the shell loads
    private var viewingCurrent = true
    /// Current UI state only. It is injected into the in-memory page and never written to Activity.
    private var readinessStatus: JarvisReadiness.Status = .stopped

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

        let headerHeight: CGFloat = 50
        let header = NSVisualEffectView(frame: NSRect(x: 0,
                                                      y: content.bounds.height - headerHeight,
                                                      width: content.bounds.width,
                                                      height: headerHeight))
        header.autoresizingMask = [.width, .minYMargin]
        header.material = .headerView
        header.blendingMode = .withinWindow
        header.state = .active

        let pop = NSPopUpButton(frame: .zero)
        pop.translatesAutoresizingMaskIntoConstraints = false
        pop.target = self
        pop.action = #selector(sessionChanged)
        pop.toolTip = "Switch between this and previous sessions"
        pop.setAccessibilityLabel("Session")
        pop.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.addSubview(pop)
        self.picker = pop

        let copyID = NSButton(title: "Copy ID", target: self, action: #selector(copySessionIDTapped))
        copyID.translatesAutoresizingMaskIntoConstraints = false
        copyID.bezelStyle = .rounded
        copyID.toolTip = "Copy the exact session ID"
        header.addSubview(copyID)
        self.copySessionIDButton = copyID

        let evaluate = NSButton(title: "Evaluate", target: self, action: #selector(evaluateTapped))
        evaluate.translatesAutoresizingMaskIntoConstraints = false
        evaluate.bezelStyle = .rounded
        header.addSubview(evaluate)
        self.evaluateButton = evaluate

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
            pop.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            pop.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            pop.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            preferredPickerWidth,
            copyID.leadingAnchor.constraint(equalTo: pop.trailingAnchor, constant: 8),
            copyID.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            copyID.widthAnchor.constraint(equalToConstant: 72),
            copyID.trailingAnchor.constraint(lessThanOrEqualTo: evaluate.leadingAnchor, constant: -8),
            evaluate.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            evaluate.widthAnchor.constraint(equalToConstant: 96),
            evaluate.trailingAnchor.constraint(equalTo: clear.leadingAnchor, constant: -8),
            clear.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            clear.widthAnchor.constraint(equalToConstant: 110),
            clear.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
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
        evaluateButton = nil
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
        refreshEvaluateButtonState()
    }

    @objc private func sessionChanged() {
        guard let idx = picker?.indexOfSelectedItem, sessions.indices.contains(idx) else { return }
        let s = sessions[idx]
        if s.isCurrent { loadCurrent() } else { loadPast(s) }
        refreshCopySessionIDButtonState()
        refreshEvaluateButtonState()
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

    /// Coaching started or stopped (AppDelegate calls this from Start/Stop): evaluation/report
    /// presentation is suppressed until the full coaching lifecycle has ended.
    func coachingStateDidChange() {
        refreshEvaluateButtonState()
    }

    /// Render the Core composition result for the current session. Past sessions intentionally show
    /// only Ended rather than reconstructing transient readiness history that was never persisted.
    func readinessDidChange(_ status: JarvisReadiness.Status) {
        readinessStatus = status
        refreshReadinessBadge()
    }

    /// A dev-side evaluator may also have written a report while Settings was on another tab.
    func didBecomeActive() {
        refreshEvaluateButtonState()
    }

    /// Evaluate and Clear stay disabled for the full coaching lifecycle and while an evaluation is
    /// in flight. A completed session with a saved report keeps the established Open report action.
    private func refreshEvaluateButtonState() {
        let coachingRunning = isCoachingRunning?() == true
        clearHistoryButton?.isEnabled = !coachingRunning && !isEvaluating
        guard let button = evaluateButton else { return }
        if isEvaluating {
            button.title = "Evaluating…"
            button.toolTip = "The agentic evaluator is inspecting this session"
            button.isEnabled = false
            return
        }
        guard let idx = picker?.indexOfSelectedItem, sessions.indices.contains(idx) else {
            button.title = "Evaluate"
            button.toolTip = "No session selected"
            button.isEnabled = false
            return
        }
        let session = sessions[idx]
        if coachingRunning {
            button.title = AgenticEvaluation.savedReport(in: session.url) == nil
                ? "Evaluate" : "Open report"
            button.toolTip = "Stop Jarvis before evaluating or opening a report"
            button.isEnabled = false
            return
        }
        guard isSessionAuditClosed?(session.url) != false else {
            button.title = AgenticEvaluation.savedReport(in: session.url) == nil
                ? "Evaluate" : "Open report"
            button.toolTip = "This session's audit is still closing"
            button.isEnabled = false
            return
        }
        if AgenticEvaluation.savedReport(in: session.url) != nil {
            button.title = "Open report"
            button.toolTip = "Open this session's evaluation report in your browser"
            button.isEnabled = true
        } else {
            button.title = "Evaluate"
            button.toolTip = "Run an agentic audit over this session and the Jarvis source checkout"
            button.isEnabled = true
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
        let snapshot = store.entrySnapshot(
            for: session,
            retainingMostRecentInsertions: ActivityLog.retainedEntryLimit)
        let rows = snapshot.entries.map { entry, data in
            ActivityLog.rowScript(time: entry.time, message: entry.message,
                                  imageBase64: data?.base64EncodedString())
        }
        beginLoad(shell: ActivityLog.htmlShell(), rows: rows,
                  shown: rows.count, total: snapshot.total)
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
        refreshReadinessBadge()
    }

    private func refreshReadinessBadge() {
        guard loaded else { return }
        let badge = viewingCurrent
            ? readinessStatus.activityBadge
            : (label: "Ended", state: "stopped")
        let script = "setReadiness(\(jsString(badge.label)),\(jsString(badge.state)));"
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: - Session evaluation

    /// One click runs the sole agentic evaluator over the source checkout plus the selected session,
    /// saves `eval-report.md`, and opens it. An existing report is reopened without re-billing.
    @objc private func evaluateTapped() {
        guard isCoachingRunning?() != true else {
            jlog("Jarvis: suppressed Activity evaluation presentation while coaching is running.")
            return
        }
        guard let idx = picker?.indexOfSelectedItem, sessions.indices.contains(idx) else { return }
        let session = sessions[idx]
        guard isSessionAuditClosed?(session.url) != false else {
            jlog("Jarvis: suppressed evaluation while the selected session audit is closing.")
            return
        }
        if let report = AgenticEvaluation.savedReport(in: session.url) {
            openReport(report, for: session)
            return
        }
        guard AgenticEvaluation.hasTraffic(in: session.url) else {
            info("Nothing to evaluate",
                 "This session has no recorded brain traffic. Traffic starts with the first coaching turn.")
            return
        }
        guard let evaluator = makeEvaluator?() else {
            info("Evaluation unavailable",
                 "Jarvis couldn't locate the source checkout required by the agentic evaluator.")
            return
        }

        isEvaluating = true
        refreshEvaluateButtonState()
        evaluationTask = Task { [weak self] in
            defer {
                self?.evaluationTask = nil
                self?.isEvaluating = false
                self?.refreshEvaluateButtonState()
            }
            do {
                let report = try await evaluator.evaluate(sessionDirectory: session.url)
                self?.openReport(report, for: session)
            } catch is CancellationError {
                jlog("Jarvis: Activity evaluation was cancelled.")
            } catch {
                jlog("Jarvis: Activity evaluation failed — \(error.localizedDescription)")
                self?.info("Evaluation failed", error.localizedDescription)
            }
        }
    }

    /// App termination must propagate cancellation to `AgentCLIProcessRunner`, which kills the
    /// evaluator subprocess immediately instead of letting it outlive Jarvis and keep using quota.
    func cancelEvaluation() {
        evaluationTask?.cancel()
        evaluationTask = nil
        isEvaluating = false
        refreshEvaluateButtonState()
    }

    /// Open the report in the user's browser: render the markdown to `eval-report.html` beside it
    /// (regenerated every open, so it never goes stale after an agentic re-audit rewrites the `.md`)
    /// and hand the page to the default browser. The page carries a "Copy as Markdown"
    /// button so the raw report can be pasted into an agent chat to work on the findings.
    private func openReport(_ report: String, for session: SessionStore.Session) {
        guard isCoachingRunning?() != true else {
            jlog("Jarvis: suppressed Activity report presentation while coaching is running.")
            return
        }
        guard isSessionAuditClosed?(session.url) != false else {
            jlog(
                "Jarvis: suppressed report presentation while the selected session audit is closing.")
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
        alert.informativeText = "This permanently deletes all previous sessions (logs and "
            + "screenshots). The current session and any session still owned by audit work are kept."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return } // ghost-mode-allowed: guarded explicit Activity action
        store.clearHistory(preserving: protectedSessionDirectories?() ?? [])
        populatePicker()
        loadCurrent()   // the viewed session may be gone; fall back to the live one
    }

    /// Encode a Swift string as a JS string literal (for `setMeta`).
    private func jsString(_ s: String) -> String {
        (try? String(data: JSONEncoder().encode(s), encoding: .utf8)) ?? "\"\""
    }
}

private extension JarvisReadiness.Status {
    var activityBadge: (label: String, state: String) {
        switch self {
        case .checking:
            ("Starting", "starting")
        case .blocked:
            ("Blocked", "blocked")
        case .recovering:
            ("Recovering", "recovering")
        case .ready(.full):
            ("Ready", "ready")
        case .ready(.microphoneOnly):
            ("Microphone only", "microphone-only")
        case .stopped:
            ("Stopped", "stopped")
        }
    }
}
