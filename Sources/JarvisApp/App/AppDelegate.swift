import AppKit
import JarvisCore
import JarvisOverlay

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let clock = SystemClock()
    private let config = Config.default
    private let transcript = RollingTranscript()
    private let keychain = KeychainSecretStore()
    private lazy var secrets = ChainedSecretStore([keychain, EnvSecretStore()])

    private var overlay: OverlayPanel!
    private var menuBar: MenuBarController!
    private var activityViewer: ActivityViewer?    // dev mode only; the in-app activity log window
    /// Two transcription sockets feeding one shared transcript: mic → `.me`, system audio → `.them`.
    private var transcriber: RealtimeTranscriber?       // "me" (mic)
    private var themTranscriber: RealtimeTranscriber?   // "them" (system audio)
    private var audio: AudioInput?
    private var systemAudio: SystemAudioInput?
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
            ActivityLog.shared.enable(directory: dir)        // <dir>/jarvis-activity.jsonl, 0600, fresh
            // The viewer can browse every past session under the base log dir; clear-history spares
            // this one.
            activityViewer = ActivityViewer(log: .shared,
                                            store: SessionStore(base: devLogDirectory(), current: dir))
            jlog("Jarvis: dev mode — session \(dir.lastPathComponent) (\(dir.path)).")
        }

        // Ask for Microphone + Screen Recording up front, not lazily mid-session.
        Permissions.primeAll()

        overlay = OverlayPanel()
        menuBar = MenuBarController(keychain: keychain, showLogViewer: devMode)
        // Dev mode: open this session's activity in the in-app viewer window on demand.
        menuBar.onOpenLogViewer = { [weak self] in
            guard let viewer = self?.activityViewer else { jlog("Jarvis: no activity log to open yet."); return }
            viewer.show()
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
        let driver = CoachDriver(config: config, transcript: transcript,
                                 brain: brain, screen: ScreenCaptureCLI(), overlay: overlay, clock: clock,
                                 onSpoke: { [weak self] in Task { @MainActor in self?.menuBar.noteSpoke() } })

        // CoachDriver is @unchecked Sendable; capture it (not @MainActor self) in the callbacks.
        // Route turns through TurnTaskBox so Stop can cancel an in-flight one. Concurrent triggers are
        // coalesced inside CoachDriver (the running turn batches them in), so we don't cancel here.
        let turns = TurnTaskBox()
        // Mic socket gave up (bad key / quota): coaching can't continue, so stop cleanly and correct
        // the menu instead of lying 🟢.
        let onMicTerminalFailure: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.stop(); self?.menuBar.setRunning(false) }
        }
        // "Them" socket gave up: degrade gracefully — tear down ONLY the system-audio side and keep
        // the mic running (matches the SystemAudioInput contract). The menu stays 🟢.
        let onThemTerminalFailure: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                self?.themTranscriber?.stop(); self?.themTranscriber = nil
                self?.systemAudio?.stop(); self?.systemAudio = nil
                jlog("Jarvis: 'them' (system audio) socket gave up — mic side still active")
            }
        }

        // "Me" side: the mic. Drives turn-end and the backing-off silence check ("are you stuck?").
        let transcriber = RealtimeTranscriber(apiKey: key, model: config.transcriptionModel,
                                              speaker: .me, transcript: transcript, clock: clock,
                                              silenceTimeout: config.silenceTimeoutSeconds,
                                              silenceMaxInterval: config.silenceMaxIntervalSeconds,
                                              silenceDurationMs: config.vadSilenceDurationMs,
                                              turnDebounce: config.turnDebounceSeconds,
                                              maxBufferedAudioSeconds: config.maxBufferedAudioSeconds)
        transcriber.onTurnEnd = { turns.run { await driver.handleTrigger(.turnEnd) } }
        transcriber.onSilence = { secs in turns.run { await driver.handleTrigger(.silence(secondsQuiet: secs)) } }
        transcriber.onTerminalFailure = onMicTerminalFailure

        // "Them" side: system audio (remote participants). Drives turn-end so Jarvis can react when the
        // other side finishes (e.g. asks you something), but NOT the silence check — the "are you
        // stuck?" prompt is about the *user*, so only the mic owns that timer.
        let themTranscriber = RealtimeTranscriber(apiKey: key, model: config.transcriptionModel,
                                                  speaker: .them, transcript: transcript, clock: clock,
                                                  silenceTimeout: config.silenceTimeoutSeconds,
                                                  silenceMaxInterval: config.silenceMaxIntervalSeconds,
                                                  silenceDurationMs: config.vadSilenceDurationMs,
                                                  turnDebounce: config.turnDebounceSeconds,
                                                  maxBufferedAudioSeconds: config.maxBufferedAudioSeconds)
        themTranscriber.onTurnEnd = { turns.run { await driver.handleTrigger(.turnEnd) } }
        themTranscriber.onTerminalFailure = onThemTerminalFailure

        let audio = AudioInput { [weak transcriber] pcm in transcriber?.sendAudio(pcm) }
        let systemAudio = SystemAudioInput { [weak themTranscriber] pcm in themTranscriber?.sendAudio(pcm) }
        // If the SCStream dies mid-session (permission revoked, display change), degrade the same way
        // as a "them" socket failure: drop the system-audio side, keep the mic coaching.
        systemAudio.onTerminalFailure = onThemTerminalFailure
        self.transcriber = transcriber
        self.themTranscriber = themTranscriber
        self.audio = audio
        self.systemAudio = systemAudio
        self.turns = turns
        transcriber.connect()
        themTranscriber.connect()
        audio.start()
        systemAudio.start()
        jlog("Jarvis: coaching started (mic + system audio).")
        return true
    }

    /// Stop and tear down BOTH transcription pipelines (mic/"me" and system-audio/"them"). Safe to
    /// call when already stopped. Both sides must be torn down: otherwise the "them" SCStream keeps
    /// capturing and its socket keeps streaming after Stop, and its turn triggers could still drive a
    /// coaching turn on a torn-down driver — the exact "speak after Stop" failure the turns box exists
    /// to prevent. A subsequent Start would also leak the orphaned stream/socket and double-transcribe.
    private func stop() {
        let wasRunning = transcriber != nil || themTranscriber != nil
        turns?.cancelAll(); turns = nil      // cancel any in-flight coaching turn
        transcriber?.stop()
        themTranscriber?.stop()
        audio?.stop()
        systemAudio?.stop()
        transcriber = nil
        themTranscriber = nil
        audio = nil
        systemAudio = nil
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
