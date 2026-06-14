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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar app, no Dock icon

        overlay = OverlayPanel()
        menuBar = MenuBarController(guardrails: guardrails, keychain: keychain)
        // Pasting a key in the menu starts coaching immediately — no relaunch.
        menuBar.onKeySaved = { [weak self] key in self?.applyKey(key) }

        // Start now if a key is already present (Keychain or OPENAI_API_KEY).
        if let key = secrets.apiKey(), !key.isEmpty {
            applyKey(key)
        } else {
            NSLog("Jarvis: no API key yet — paste it via the menu bar (it saves to your Keychain).")
        }
    }

    /// (Re)build the brain + driver for `key` and (re)start the transcription pipeline.
    private func applyKey(_ key: String) {
        // Tear down any existing pipeline so a new key replaces it cleanly.
        transcriber?.stop()
        audio?.stop()
        transcriber = nil
        audio = nil

        let brain = OpenAIBrainClient(apiKey: key, model: config.brainModel,
                                      reasoningEffort: config.reasoningEffort)
        let driver = CoachDriver(config: config, transcript: transcript, guardrails: guardrails,
                                 brain: brain, screen: ScreenCaptureCLI(), overlay: overlay, clock: clock)
        driver.onSpoke = { [weak self] in Task { @MainActor in self?.menuBar.noteSpoke() } }
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
        NSLog("Jarvis: coaching started.")
    }
}
