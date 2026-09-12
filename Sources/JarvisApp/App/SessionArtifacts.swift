import AppKit
import JarvisCore
import JarvisEvaluation

/// Owns everything a coaching session leaves on disk.
///
/// One of the three owners the app delegate was split into (wiki/lean-coaching-core.md, Phase 5).
/// The boundary: **the session runtime** starts, stops, and tears down a session and applies
/// readiness and capture-health effects; **brain composition** builds and reapplies the provider
/// route; and **this type** owns the session directory, the evidence handle installed in it, the
/// Activity projection's session, retention pruning, and the close bookkeeping that keeps a session
/// whose evidence is still sealing from being deleted or evaluated.
///
/// It performs no coaching work and holds no lifecycle state of its own beyond what is on disk: the
/// runtime asks it to open a session and to hand that session back at teardown.
@MainActor
final class SessionArtifacts {
    /// Called when a Start rotates the session directory, so the viewer can re-point its history
    /// browser at the new current session and show it live.
    var onSessionDidChange: ((_ base: URL, _ current: URL?) -> Void)?
    /// Called after retention pruning, so a picker built from the pre-prune listing drops the rows
    /// that no longer exist.
    var onHistoryDidChange: (() -> Void)?

    /// Only for locating the per-user app-data directory the default log base sits beside; this
    /// type never reads a secret.
    private let secretFile = FileSecretStore()

    /// One per-session handle over the process-level audit worker. Brain clients and `CoachDriver`
    /// retain only its narrow observer ports, so late work remains attributed to the session that
    /// created it while Stop → Start can rotate immediately to a fresh handle.
    private(set) var sessionAudit: FileSessionAudit?
    /// The current session's log directory (set by `beginNewSession`) — also where `CLIBrainClient`
    /// materializes screenshots for a CLI brain, keeping all screen-derived bytes in one owner-only place.
    private(set) var currentSessionDir: URL?
    /// Normal Stop protects and gates only the directory whose immutable terminal marker is pending.
    /// The path leaves this set after `close()` returns; closed audits never become mutable again.
    private var closingAuditPaths: Set<String> = []
    /// How many past session log *directories* to keep on disk; older ones are pruned at each Start so
    /// the always-on activity log stays bounded across launches. This caps session count, not the size
    /// of any one session — a very long single run still grows its (append-only) logs + screenshots.
    /// Clear all but the current via the viewer's "Clear history".
    private static let retainedSessions = 10


    /// Open a fresh session: a new per-Start subdirectory under the base log dir, with its own
    /// `jarvis-debug.log` and `jarvis-activity.jsonl`. Called on every Start so each coaching run keeps
    /// its own logs instead of resuming the previous run's.
    @discardableResult
    func beginNewSession() -> FileSessionAudit {
        let base = logDirectory()
        let dir = base.appendingPathComponent(newSessionID())
        // 0700: the screenshots/logs inside are 0600, so the directory holding them must be owner-only
        // too — otherwise a 0755 dir leaks file names/counts/timestamps to other local users (CWE-732).
        // Applies to the created session dir and any intermediates.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // createDirectory only sets the mode on dirs it *creates*; a pre-existing base (e.g. a 0755
        // Application Support/Jarvis left by another tool) keeps its mode, which would leak session-dir
        // names. Tighten it best-effort, mirroring FileSecretStore.setApiKey.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        // Evidence file creation and later writes run on the shared bounded evidence worker. Start only
        // creates a lightweight session handle and never waits for an older session's disk access.
        // The human-facing projection is composed here, not reached for inside the kernel: the
        // handle owns the one admission point, and ActivityLog renders what the worker hands it.
        let audit = FileSessionAudit(directory: dir, activity: ActivityLog.shared)
        sessionAudit = audit
        // The projection rotates to this session by identity, so the previous session's still-
        // draining rows and its background close land in its own files, never in this window.
        ActivityLog.shared.enable(directory: dir, session: audit.sessionID)
        // Diagnostics join that same handle: <dir>/jarvis-debug.log, 0600, fresh, written by the
        // worker rather than by whichever thread called jlog.
        JarvisLog.attach(to: audit)
        currentSessionDir = dir
        // Point the viewer's history browser at the new current session and show it live; clear-history
        // spares whichever session is current.
        onSessionDidChange?(base, dir)
        jlog("Jarvis: session \(dir.lastPathComponent) (\(dir.path)).")
        pruneRetainedSessions(base: base, current: dir)
        return audit
    }

    /// Bound the session directory, off the Start path.
    ///
    /// Sessions accumulate every launch, so old ones have to go — but a directory listing and a
    /// recursive delete are disk work that can only ever slow the user down. They can never make
    /// Jarvis hear, reason, capture, or deliver better, so they are maintenance, not admission
    /// (wiki/lean-coaching-core.md, Phase 3). Creating the owner-only session directory stays on
    /// Start; this does not.
    ///
    /// The protected set is read here rather than captured at Start so a session that is still
    /// sealing its evidence is spared by its state at delete time, and the scan itself runs off the
    /// main actor. Failure is silent by construction: nothing awaits this, and nothing reports it.
    func pruneRetainedSessions(base: URL, current: URL) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let store = SessionStore(base: base, current: current)
            let protected = self.protectedAuditDirectories()
            let keep = Self.retainedSessions
            await Task.detached(priority: .utility) {
                store.pruneToMostRecent(keep, preserving: protected)
            }.value
            // The picker was built from the pre-prune listing; drop the rows that no longer exist.
            self.onHistoryDidChange?()
        }
    }

    func isAuditClosed(for directory: URL) -> Bool {
        !closingAuditPaths.contains(directory.standardizedFileURL.path)
    }

    /// Protect only directories still owned by a normal Stop close. Closed audits never reopen.
    func protectedAuditDirectories() -> Set<URL> {
        Set(closingAuditPaths.map { URL(fileURLWithPath: $0, isDirectory: true) })
    }

    /// Build identity is part of the directory name already created at Start, not a second file.
    func newSessionID() -> String {
        SessionDirectoryID.make(
            isDevelopmentBuild: Bundle.main.infoDictionary?["JarvisDevelopmentBuild"] as? Bool == true,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
    }

    /// Bundle location, not launch arguments or cwd, keeps each development worktree's history
    /// beside its source. The same base feeds Start, Activity, and retention.
    func logDirectory() -> URL {
        SessionStore.baseDirectory(
            isDevelopmentBuild: Bundle.main.infoDictionary?["JarvisDevelopmentBuild"] as? Bool == true,
            bundleURL: Bundle.main.bundleURL,
            appDataDirectory: secretFile.directoryURL)
    }

    func evaluationSource(for session: URL) -> EvaluationSource {
        EvaluationSource.resolve(
            isDevelopmentBuild: Bundle.main.infoDictionary?["JarvisDevelopmentBuild"] as? Bool == true,
            bundleURL: Bundle.main.bundleURL,
            sessionID: session.lastPathComponent,
            currentVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
    }

    var evaluationSourceStore: ReleaseSourceStore {
        ReleaseSourceStore(root: secretFile.directoryURL.appendingPathComponent("source"))
    }

    /// Hand the live session back at teardown and forget it, so a replacement Start opens a fresh
    /// directory and handle without waiting for this one to seal.
    func takeCurrentSession() -> (audit: FileSessionAudit?, directory: URL?) {
        let taken = (sessionAudit, currentSessionDir)
        sessionAudit = nil
        return taken
    }

    /// A normal Stop's close is running for this directory: protect it from pruning and gate
    /// evaluation until the terminal marker lands.
    func beginClosing(_ directory: URL) {
        closingAuditPaths.insert(directory.standardizedFileURL.path)
    }

    /// The close returned. Closed audits never become mutable again.
    func endClosing(_ directory: URL) {
        closingAuditPaths.remove(directory.standardizedFileURL.path)
    }
}
