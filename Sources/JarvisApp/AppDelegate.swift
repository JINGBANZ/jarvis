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

        let brain = OpenAIBrainClient(apiKey: secrets.apiKey() ?? "", model: config.brainModel)
        driver = CoachDriver(config: config, transcript: transcript, guardrails: guardrails,
                             brain: brain, screen: ScreenCaptureCLI(), overlay: overlay, clock: clock)
        driver.onSpoke = { [weak self] in Task { @MainActor in self?.menuBar.noteSpoke() } }

        startTranscription()
    }

    /// Guarded so the app still launches without an API key (set it via the menu bar, relaunch).
    private func startTranscription() {
        guard let key = secrets.apiKey(), !key.isEmpty else {
            NSLog("Jarvis: no API key yet — set it via the menu bar, then relaunch.")
            return
        }
        let driver = self.driver!  // CoachDriver is @unchecked Sendable; capture it, not self.
        let transcriber = RealtimeTranscriber(apiKey: key, model: config.transcriptionModel,
                                              transcript: transcript, clock: clock,
                                              silenceTimeout: config.silenceTimeoutSeconds)
        transcriber.onTurnEnd = { Task { await driver.handleTrigger(.turnEnd) } }
        transcriber.onSilence = { secs in Task { await driver.handleTrigger(.silence(secondsQuiet: secs)) } }
        let audio = AudioInput(captureSystemAudio: true) { [weak transcriber] pcm in
            transcriber?.sendAudio(pcm)
        }
        self.transcriber = transcriber
        self.audio = audio
        transcriber.connect()
        audio.start()
    }
}
