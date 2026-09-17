import AppKit
import JarvisCore
import JarvisEvaluation

@MainActor
final class SessionArtifacts {
    var onSessionDidChange: ((_ base: URL, _ current: URL?) -> Void)?
    var onHistoryDidChange: (() -> Void)?

    // Used only to locate the app-data directory; this type never reads a secret.
    private let secretFile = FileSecretStore()

    private(set) var sessionAudit: FileSessionAudit?
    private(set) var currentSessionDir: URL?
    private var closingAuditPaths: Set<String> = []
    private static let retainedSessions = 10
    private let baseDirectory: URL?

    /// A non-nil `baseDirectory` is caller-owned: sessions go there and retention is left to the
    /// caller.
    init(baseDirectory: URL? = nil) {
        self.baseDirectory = baseDirectory
    }

    @discardableResult
    func beginNewSession() -> FileSessionAudit {
        let base = logDirectory()
        let dir = base.appendingPathComponent(newSessionID())
        // 0700: otherwise the directory leaks the 0600 files' names and timestamps to other local
        // users (CWE-732).
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // createDirectory leaves an existing base's mode alone, so tighten it too.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        let audit = FileSessionAudit(directory: dir, activity: ActivityLog.shared)
        sessionAudit = audit
        ActivityLog.shared.enable(directory: dir, session: audit.sessionID)
        JarvisLog.attach(to: audit)
        currentSessionDir = dir
        onSessionDidChange?(base, dir)
        jlog("Jarvis: session \(dir.lastPathComponent) (\(dir.path)).")
        if baseDirectory == nil {
            pruneRetainedSessions(base: base, current: dir)
        }
        return audit
    }

    /// Reads the protected set at delete time, not at Start, so a session still sealing its
    /// evidence is spared.
    func pruneRetainedSessions(base: URL, current: URL) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let store = SessionStore(base: base, current: current)
            let protected = self.protectedAuditDirectories()
            let keep = Self.retainedSessions
            await Task.detached(priority: .utility) {
                store.pruneToMostRecent(keep, preserving: protected)
            }.value
            self.onHistoryDidChange?()
        }
    }

    func isAuditClosed(for directory: URL) -> Bool {
        !closingAuditPaths.contains(directory.standardizedFileURL.path)
    }

    func protectedAuditDirectories() -> Set<URL> {
        Set(closingAuditPaths.map { URL(fileURLWithPath: $0, isDirectory: true) })
    }

    func newSessionID() -> String {
        SessionDirectoryID.make(
            isDevelopmentBuild: Bundle.main.infoDictionary?["JarvisDevelopmentBuild"] as? Bool == true,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
    }

    /// Derived from the bundle location, not cwd or arguments, so each development worktree keeps
    /// its history beside its source.
    func logDirectory() -> URL {
        if let baseDirectory { return baseDirectory }
        return SessionStore.baseDirectory(
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

    func takeCurrentSession() -> (audit: FileSessionAudit?, directory: URL?) {
        let taken = (sessionAudit, currentSessionDir)
        sessionAudit = nil
        return taken
    }

    /// Call when a normal Stop's close starts, and `endClosing` once `close()` returns. Until then
    /// the directory is spared from pruning and its evaluation is gated.
    func beginClosing(_ directory: URL) {
        closingAuditPaths.insert(directory.standardizedFileURL.path)
    }

    func endClosing(_ directory: URL) {
        closingAuditPaths.remove(directory.standardizedFileURL.path)
    }
}
