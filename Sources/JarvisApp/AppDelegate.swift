import AppKit
import JarvisCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let clock = SystemClock()
    private let config = Config.default
    private let transcript = RollingTranscript()
    private let keychain = KeychainSecretStore()
    private lazy var guardrails = Guardrails(
        cooldownSeconds: config.cooldownSeconds,
        maxInterjectionsPerMinute: config.maxInterjectionsPerMinute,
        clock: clock)
    private lazy var secrets = ChainedSecretStore([keychain, EnvSecretStore()])

    private var overlay: OverlayPanel!
    private var menuBar: MenuBarController!
    private var transcriber: RealtimeTranscriber?
    private var audio: AudioInput?
    /// In-flight coaching turns, so Stop can cancel one mid-brain-call (otherwise it could speak
    /// after the user pressed Stop).
    private var turns: TurnTaskBox?

    /// Dev mode (`open ./Jarvis.app --args --dev`): enables owner-only file logging for the session.
    /// The activity HTML is opened on demand from the menu bar, not auto-opened on launch.
    private let devMode = CommandLine.arguments.contains("--dev")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar app, no Dock icon

        if devMode {
            // Each dev-mode launch is its own session: nest logs under a unique per-launch
            // subdirectory so each debug/dev run keeps its own separated logs.
            let dir = devLogDirectory().appendingPathComponent(newSessionID())
            // 0700: the screenshots/logs inside are 0600, so the directory holding them must be
            // owner-only too — otherwise a 0755 dir leaks file names/counts/timestamps to other
            // local users (CWE-732). Applies to the created session dir and any intermediates.
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            JarvisLog.enableFileLogging(directory: dir)     // <dir>/jarvis-debug.log, 0600, fresh
            ActivityLog.shared.enable(directory: dir)        // <dir>/jarvis-activity.html, 0600, fresh
            jlog("Jarvis: dev mode — session \(dir.lastPathComponent) (\(dir.path)).")
            jlog("Jarvis: pick “Open Log Viewer” from the menu bar to watch this session.")
        }

        // Ask for Microphone + Screen Recording up front, not lazily mid-session.
        Permissions.primeAll()

        overlay = OverlayPanel()
        menuBar = MenuBarController(keychain: keychain, showLogViewer: devMode)
        // Dev mode: open this session's activity HTML on demand.
        menuBar.onOpenLogViewer = {
            guard let url = ActivityLog.shared.htmlURL else { jlog("Jarvis: no activity log to open yet."); return }
            if !NSWorkspace.shared.open(url) { jlog("Jarvis: couldn't open the activity log viewer (\(url.path)).") }
        }
        // The menu drives the pipeline lifecycle. Jarvis does NOT auto-start; the user presses Start.
        menuBar.onStart = { [weak self] in self?.start() ?? false }
        menuBar.onStop = { [weak self] in self?.stop() }
        // A pasted key is stored but does not auto-start; restart only if already running, and
        // reflect the real outcome back into the menu state.
        menuBar.onKeySaved = { [weak self] _ in
            guard let self, self.transcriber != nil else { return }
            self.menuBar.setRunning(self.start())
        }

        if secrets.apiKey()?.isEmpty == false {
            jlog("Jarvis: ready — press Start in the menu bar to begin coaching.")
        } else {
            jlog("Jarvis: no API key yet — paste it via the menu bar, then press Start.")
        }
    }

    /// Build the brain + driver and start the transcription pipeline. Returns `false` (and stays
    /// stopped) if no API key is available yet.
    @discardableResult
    private func start() -> Bool {
        guard let key = secrets.apiKey(), !key.isEmpty else {
            jlog("Jarvis: can't start — no API key.")
            warnNoKey()
            return false
        }
        stop() // tear down any existing pipeline so we start cleanly
        menuBar.resetCounter()  // a Start begins a fresh session

        let brain = OpenAIBrainClient(apiKey: key, model: config.brainModel,
                                      reasoningEffort: config.reasoningEffort)
        let driver = CoachDriver(config: config, transcript: transcript, guardrails: guardrails,
                                 brain: brain, screen: ScreenCaptureCLI(), overlay: overlay, clock: clock,
                                 onSpoke: { [weak self] in Task { @MainActor in self?.menuBar.noteSpoke() } })

        let transcriber = RealtimeTranscriber(apiKey: key, model: config.transcriptionModel,
                                              transcript: transcript, clock: clock,
                                              silenceTimeout: config.silenceTimeoutSeconds)
        // CoachDriver is @unchecked Sendable; capture it (not @MainActor self) in the callbacks.
        // Route turns through TurnTaskBox so Stop can cancel an in-flight one.
        let turns = TurnTaskBox()
        transcriber.onTurnEnd = { turns.run { await driver.handleTrigger(.turnEnd) } }
        transcriber.onSilence = { secs in turns.run { await driver.handleTrigger(.silence(secondsQuiet: secs)) } }
        // Reconnect gave up (bad key / quota): stop cleanly and correct the menu instead of lying 🟢.
        transcriber.onTerminalFailure = { [weak self] in
            Task { @MainActor in self?.stop(); self?.menuBar.setRunning(false) }
        }
        let audio = AudioInput(captureSystemAudio: true) { [weak transcriber] pcm in
            transcriber?.sendAudio(pcm)
        }
        self.transcriber = transcriber
        self.audio = audio
        self.turns = turns
        transcriber.connect()
        audio.start()
        jlog("Jarvis: coaching started.")
        return true
    }

    /// Stop and tear down the transcription pipeline. Safe to call when already stopped.
    private func stop() {
        let wasRunning = transcriber != nil
        turns?.cancelAll(); turns = nil      // cancel any in-flight coaching turn
        transcriber?.stop()
        audio?.stop()
        transcriber = nil
        audio = nil
        if wasRunning { jlog("Jarvis: stopped.") }
    }

    private func warnNoKey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "No OpenAI API key set"
        alert.informativeText = "Choose “Set OpenAI API Key…” from the Jarvis menu, then press Start."
        alert.alertStyle = .informational
        alert.runModal()
    }

    /// A unique id for this dev-mode launch, used as the session's log subdirectory name. Sortable
    /// timestamp + a short random suffix so two launches in the same second don't collide.
    private func newSessionID() -> String {
        let f = DateFormatter()
        // Fixed-format timestamp: pin locale + calendar so the name is always Gregorian yyyy-MM-dd
        // and lexically sortable, regardless of the user's locale or system calendar (Apple QA1480).
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let suffix = String(UUID().uuidString.prefix(4))
        return "\(f.string(from: Date()))_\(suffix)"
    }

    /// Where dev-mode logs go: `--log-dir <path>` (run-dev.sh passes the workspace `.jarvis/`),
    /// else a per-user Caches/Jarvis directory. Never `/tmp` (world-readable, shared across users).
    /// Each launch nests a per-session subdirectory under this base (see `newSessionID`).
    private func devLogDirectory() -> URL {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--log-dir"), i + 1 < args.count {
            return URL(fileURLWithPath: args[i + 1])
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("Jarvis")
    }
}

/// Tracks the unstructured Tasks spawned per transcription trigger so Stop can cancel any in-flight
/// coaching turn. `@unchecked Sendable`: all access to `tasks` is guarded by the lock.
private final class TurnTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []

    func run(_ op: @escaping @Sendable () async -> Void) {
        let task = Task { await op() }
        lock.lock()
        tasks.removeAll { $0.isCancelled }
        tasks.append(task)
        lock.unlock()
    }

    func cancelAll() {
        lock.lock(); let snapshot = tasks; tasks.removeAll(); lock.unlock()
        snapshot.forEach { $0.cancel() }
    }
}
