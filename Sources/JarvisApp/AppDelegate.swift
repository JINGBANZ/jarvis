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
        maxDirectAddressesPerMinute: config.maxDirectAddressesPerMinute,
        clock: clock)
    private lazy var secrets = ChainedSecretStore([keychain, EnvSecretStore()])

    private var overlay: OverlayPanel!
    private var menuBar: MenuBarController!
    private var transcriber: RealtimeTranscriber?
    private var audio: AudioInput?
    /// In-flight coaching turns, so Stop can cancel one mid-brain-call (otherwise it could speak
    /// after the user pressed Stop).
    private var turns: TurnTaskBox?

    /// Dev mode (`open ./Jarvis.app --args --dev`): enables owner-only file logging and auto-opens
    /// the live activity HTML for the session.
    private let devMode = CommandLine.arguments.contains("--dev")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar app, no Dock icon

        if devMode {
            let dir = devLogDirectory()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            JarvisLog.enableFileLogging(directory: dir)     // <dir>/jarvis-debug.log, 0600, fresh
            ActivityLog.shared.enable(directory: dir)        // <dir>/jarvis-activity.html, 0600, fresh
            if let url = ActivityLog.shared.htmlURL { NSWorkspace.shared.open(url) }
            jlog("Jarvis: dev mode — activity viewer opened (\(dir.path)).")
        }

        // Ask for Microphone + Screen Recording up front, not lazily mid-session.
        Permissions.primeAll()

        overlay = OverlayPanel()
        menuBar = MenuBarController(keychain: keychain)
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
                                              silenceTimeout: config.silenceTimeoutSeconds,
                                              silenceDurationMs: config.vadSilenceDurationMs,
                                              turnDebounce: config.turnDebounceSeconds)
        // CoachDriver is @unchecked Sendable; capture it (not @MainActor self) in the callbacks.
        // Route turns through TurnTaskBox so Stop can cancel an in-flight one. Fresh user speech
        // (a turn-end or a direct address) CANCELS any in-flight turn — stale coaching about a moment
        // the user already moved past is worse than a dropped turn. A silence tick does not cancel.
        let turns = TurnTaskBox()
        transcriber.onTurnEnd = { turns.run(cancelPrevious: true) { await driver.handleTrigger(.turnEnd) } }
        transcriber.onDirectAddress = { turns.run(cancelPrevious: true) { await driver.handleTrigger(.directAddress) } }
        transcriber.onSilence = { secs in turns.run(cancelPrevious: false) { await driver.handleTrigger(.silence(secondsQuiet: secs)) } }
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

    /// Where dev-mode logs go: `--log-dir <path>` (run-dev.sh passes the workspace `.jarvis/`),
    /// else a per-user Caches/Jarvis directory. Never `/tmp` (world-readable, shared across users).
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
