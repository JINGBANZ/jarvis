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
    private var driver: CoachDriver!
    private var transcriber: RealtimeTranscriber?
    private var audio: AudioInput?

    /// Dev mode (`open ./Jarvis.app --args --dev`): auto-opens the live activity HTML for the session.
    private let devMode = CommandLine.arguments.contains("--dev")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar app, no Dock icon

        if devMode {
            ActivityLog.shared.reset()                       // fresh page for this session
            NSWorkspace.shared.open(ActivityLog.shared.htmlURL)
            jlog("Jarvis: dev mode — live activity viewer opened in your browser.")
        }

        // Ask for Microphone + Screen Recording up front, not lazily mid-session.
        Permissions.primeAll()

        overlay = OverlayPanel()
        menuBar = MenuBarController(keychain: keychain)
        // The menu drives the pipeline lifecycle. Jarvis does NOT auto-start; the user presses Start.
        menuBar.onStart = { [weak self] in self?.start() ?? false }
        menuBar.onStop = { [weak self] in self?.stop() }
        // A pasted key is stored but does not auto-start; restart only if already running.
        menuBar.onKeySaved = { [weak self] _ in
            guard let self, self.transcriber != nil else { return }
            self.stop(); _ = self.start()
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
            jlog("Jarvis: can't start — no API key. Use “Set OpenAI API Key…” first.")
            return false
        }
        stop() // tear down any existing pipeline so we start cleanly

        let brain = OpenAIBrainClient(apiKey: key, model: config.brainModel,
                                      reasoningEffort: config.reasoningEffort)
        let driver = CoachDriver(config: config, transcript: transcript, guardrails: guardrails,
                                 brain: brain, screen: ScreenCaptureCLI(), overlay: overlay, clock: clock,
                                 onSpoke: { [weak self] in Task { @MainActor in self?.menuBar.noteSpoke() } })
        self.driver = driver

        let transcriber = RealtimeTranscriber(apiKey: key, model: config.transcriptionModel,
                                              transcript: transcript, clock: clock,
                                              silenceTimeout: config.silenceTimeoutSeconds)
        // CoachDriver is @unchecked Sendable; capture it (not @MainActor self) in the callbacks.
        transcriber.onTurnEnd = { Task { await driver.handleTrigger(.turnEnd) } }
        transcriber.onSilence = { secs in Task { await driver.handleTrigger(.silence(secondsQuiet: secs)) } }
        let audio = AudioInput(captureSystemAudio: true) { [weak transcriber] pcm in
            transcriber?.sendAudio(pcm)
        }
        self.transcriber = transcriber
        self.audio = audio
        transcriber.connect()
        audio.start()
        jlog("Jarvis: coaching started.")
        return true
    }

    /// Stop and tear down the transcription pipeline. Safe to call when already stopped.
    private func stop() {
        let wasRunning = transcriber != nil
        transcriber?.stop()
        audio?.stop()
        transcriber = nil
        audio = nil
        driver = nil
        if wasRunning { jlog("Jarvis: stopped.") }
    }
}
