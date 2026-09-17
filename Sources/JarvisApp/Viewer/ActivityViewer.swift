import AppKit
import WebKit
import JarvisCore
import JarvisEvaluation
import JarvisBrainProviders

@MainActor
final class ActivityViewer: NSObject, WKNavigationDelegate {
    private let log: ActivityLog
    private var store: SessionStore

    /// Called per click, so the evaluator uses the current provider selection.
    var makeEvaluator: (@MainActor (URL) -> AgenticEvaluator?)?

    /// Ghost mode: nothing here may present while this returns true.
    var isCoachingRunning: (@MainActor () -> Bool)?
    /// False while that session's audit is still closing after Stop.
    var isSessionAuditClosed: (@MainActor (URL) -> Bool)?
    /// Directories still owned by background close work must survive Clear history.
    var protectedSessionDirectories: (@MainActor () -> Set<URL>)?

    private var webView: WKWebView?
    private var picker: NSPopUpButton?
    private var copySessionIDButton: NSButton?
    private var evaluateButton: NSButton?
    private var clearHistoryButton: NSButton?
    private var exportButton: NSButton?
    /// Not reset by `teardown()`: an evaluation outlives a Settings close.
    private var isEvaluating = false
    private var isFetchingSource = false
    private var evaluationTask: Task<Void, Never>?
    private var sessions: [SessionStore.Session] = []

    private var loaded = false
    private var pending: [String] = []
    private var snapshotRows: [String] = []
    private var pendingMeta = ""
    private var evidenceIsComplete = true
    private var viewingCurrent = true
    /// UI state only, never written to Activity.
    private var readinessStatus: JarvisReadiness.Status = .stopped

    init(log: ActivityLog, store: SessionStore) {
        self.log = log
        self.store = store
    }

    // MARK: - Embeddable content view (unified Settings window)

    /// The host must call `teardown()` when its window closes.
    func makeContentView() -> NSView {
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

        let export = NSButton(title: "Export…", target: self, action: #selector(exportTapped))
        export.translatesAutoresizingMaskIntoConstraints = false
        export.bezelStyle = .rounded
        export.toolTip = "Export one or more sessions' history to a file"
        header.addSubview(export)
        self.exportButton = export

        let preferredPickerWidth = pop.widthAnchor.constraint(equalToConstant: 230)
        // Below windowSizeStayPut (500), so window resizing can compress the picker.
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
            evaluate.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
            evaluate.trailingAnchor.constraint(equalTo: clear.leadingAnchor, constant: -8),
            clear.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            clear.widthAnchor.constraint(equalToConstant: 110),
            clear.trailingAnchor.constraint(equalTo: export.leadingAnchor, constant: -8),
            export.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            export.widthAnchor.constraint(equalToConstant: 90),
            export.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
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

    func teardown() {
        log.detach()
        webView = nil
        picker = nil
        copySessionIDButton = nil
        evaluateButton = nil
        clearHistoryButton = nil
        exportButton = nil
        loaded = false
        pending = []
        snapshotRows = []
    }

    /// An open viewer must re-attach here: `ActivityLog.enable` dropped its previous observer.
    func sessionDidChange(base: URL, current: URL?) {
        store = SessionStore(base: base, current: current)
        guard webView != nil else { return }
        populatePicker()
        loadCurrent()
    }

    /// Skipped while a past session shows: `populatePicker` would reselect the current session.
    func historyDidChange() {
        guard webView != nil, viewingCurrent else { return }
        populatePicker()
    }

    // MARK: - Session list

    private func populatePicker() {
        sessions = store.listSessions()
        picker?.removeAllItems()
        for s in sessions {
            picker?.addItem(withTitle: s.isCurrent ? "\(s.label) (current)" : s.label)
        }
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

    func coachingStateDidChange() {
        refreshEvaluateButtonState()
    }

    /// Past sessions always show Ended, because readiness history is never persisted.
    func readinessDidChange(_ status: JarvisReadiness.Status) {
        readinessStatus = status
        refreshReadinessBadge()
    }

    /// A dev-side evaluator may also have written a report while Settings was on another tab.
    func didBecomeActive() {
        refreshEvaluateButtonState()
    }

    private func refreshEvaluateButtonState() {
        let coachingRunning = isCoachingRunning?() == true
        clearHistoryButton?.isEnabled = !coachingRunning && !isEvaluating
        guard let button = evaluateButton else { return }
        if isEvaluating {
            button.title = isFetchingSource ? "Fetching source…" : "Evaluating…"
            button.toolTip = isFetchingSource
                ? "Preparing the Jarvis source for this session's release"
                : "The agentic evaluator is inspecting this session"
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
        evidenceIsComplete = snap.evidenceIsComplete
        beginLoad(shell: snap.shellHTML, rows: snap.rows, shown: snap.shown, total: snap.total)
    }

    private func loadPast(_ session: SessionStore.Session) {
        viewingCurrent = false
        log.detach()
        // Unknown completeness, from a session older than the health record, shows no notice.
        evidenceIsComplete = session.evidenceIsComplete ?? true
        let snapshot = store.entrySnapshot(
            for: session,
            retainingMostRecentInsertions: ActivityLog.retainedEntryLimit)
        let rows = snapshot.entries.map { entry, data in
            ActivityLog.rowScript(time: entry.time, message: entry.message,
                                  imageBase64: data?.base64EncodedString(), response: entry.response)
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

    private func onAppend(_ js: String) {
        guard viewingCurrent else { return }
        if loaded {
            webView?.evaluateJavaScript(js, completionHandler: nil)
        } else {
            pending.append(js)
        }
    }

    // MARK: - WKNavigationDelegate

    /// Security: only the initial in-memory load may navigate, never a `data:` image or a link.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url?.absoluteString
        decisionHandler(url == nil || url == "about:blank" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        // Snapshot rows before rows buffered during the load, to keep order.
        for js in snapshotRows { webView.evaluateJavaScript(js, completionHandler: nil) }
        for js in pending { webView.evaluateJavaScript(js, completionHandler: nil) }
        snapshotRows = []
        pending = []
        webView.evaluateJavaScript("setMeta(\(jsString(pendingMeta)));", completionHandler: nil)
        webView.evaluateJavaScript(
            ActivityLog.evidenceScript(isComplete: evidenceIsComplete), completionHandler: nil)
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

    @objc private func evaluateTapped() {
        guard !isEvaluating else { return }
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
        guard let evaluator = makeEvaluator?(session.url) else { return }

        isEvaluating = true
        refreshEvaluateButtonState()
        evaluationTask = Task { [weak self] in
            defer {
                self?.evaluationTask = nil
                self?.isEvaluating = false
                self?.isFetchingSource = false
                self?.refreshEvaluateButtonState()
            }
            do {
                let report = try await evaluator.evaluate(sessionDirectory: session.url) { [weak self] fetching in
                    self?.isFetchingSource = fetching
                    self?.refreshEvaluateButtonState()
                }
                self?.openReport(report, for: session)
            } catch is CancellationError {
                jlog("Jarvis: Activity evaluation was cancelled.")
            } catch {
                jlog("Jarvis: Activity evaluation failed — \(error.localizedDescription)")
                self?.info("Evaluation failed", error.localizedDescription)
            }
        }
    }

    /// Call on quit: cancelling kills the evaluator subprocess so it can't outlive Jarvis.
    func cancelEvaluation() {
        evaluationTask?.cancel()
        evaluationTask = nil
        isEvaluating = false
        isFetchingSource = false
        refreshEvaluateButtonState()
    }

    /// Rewrites the HTML page on every open, so it never lags a re-audited `.md`.
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

    // MARK: - Export

    @objc private func exportTapped() {
        guard isCoachingRunning?() != true else {
            jlog("Jarvis: suppressed Activity export presentation while coaching is running.")
            return
        }
        ActivityExportSheet.present(sessions: sessions, store: store)
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
        case .cycleFailed(let provider):
            ("\(provider.displayName) coaching failed, still listening", "blocked")
        case .recovering(.brainResponse(let provider), _):
            ("\(provider.displayName) coaching attempt failed — retrying", "recovering")
        case .recovering:
            ("Recovering", "recovering")
        case .ready(.full):
            ("Active", "active")
        case .ready(.microphoneOnly):
            ("Microphone only", "microphone-only")
        case .stopped:
            ("Stopped", "stopped")
        }
    }
}
