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
    private var settingsWindow: SettingsWindow!
    private let appearance = OverlayAppearance()
    private var activityViewer: ActivityViewer?    // dev mode only; embedded as the Settings Activity tab
    /// Two transcription sockets feeding one shared transcript: mic → `.me`, system audio → `.them`.
    private var transcriber: RealtimeTranscriber?       // "me" (mic)
    private var themTranscriber: RealtimeTranscriber?   // "them" (system audio)
    /// One-clock capture: a single private aggregate device (built-in mic + system-output tap on one
    /// drift-compensated clock) feeds both transcription sockets, running AEC3 inside its IOProc so the
    /// other side's speaker bleed is cancelled from the mic. Replaces the separate AVAudioEngine mic +
    /// ScreenCaptureKit capture.
    private var aggregateCapture: AggregateEchoCapture?
    /// In-flight coaching turns, so Stop can cancel one mid-brain-call (otherwise it could speak
    /// after the user pressed Stop).
    private var turns: TurnTaskBox?

    /// Dev mode (`open ./Jarvis.app --args --dev`): enables owner-only file logging for the session.
    /// The activity log is available on demand from the Activity tab in Settings (dev mode only).
    private let devMode = CommandLine.arguments.contains("--dev")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar app, no Dock icon

        if devMode {
            // The activity viewer lives for the whole dev run, but a *session* is one coaching run:
            // each Start opens a fresh session dir + logs (see `beginNewSession`). No session exists
            // until the first Start, so the viewer starts with no current session to browse.
            activityViewer = ActivityViewer(log: .shared,
                                            store: SessionStore(base: devLogDirectory(), current: nil))
        }

        // Ask for Microphone + Screen Recording up front, not lazily mid-session.
        Permissions.primeAll()

        overlay = OverlayPanel()
        overlay.setFontSize(appearance.fontSize)
        overlay.setBackgroundOpacity(appearance.backgroundOpacity)

        menuBar = MenuBarController()

        // Unified Settings window: API key + overlay appearance always; the dev activity log only
        // in dev mode. A pasted key is stored but does not auto-start; restart only if already
        // running, reflecting the real outcome back into the menu state.
        var sections: [SettingsSection] = [
            APIKeySection(keychain: keychain, onKeySaved: { [weak self] _ in
                guard let self, self.transcriber != nil else { return }
                // Re-saving a key while running only re-applies it to the pipeline — it is NOT a new
                // coaching run, so keep the current session (don't rotate logs). Session rotation is
                // reserved for an explicit user Start.
                self.menuBar.setRunning(self.start(freshSession: false))
            }),
            OverlaySection(appearance: appearance, applying: overlay),
        ]
        if let viewer = activityViewer {
            sections.append(ActivitySection(viewer: viewer))
        }
        settingsWindow = SettingsWindow(sections: sections)
        menuBar.onOpenSettings = { [weak self] in self?.settingsWindow.show() }

        // The menu drives the pipeline lifecycle. Jarvis does NOT auto-start; the user presses Start.
        menuBar.onStart = { [weak self] in self?.start() ?? false }
        menuBar.onStop = { [weak self] in self?.stop() }

        if secrets.apiKey()?.isEmpty == false {
            jlog("Jarvis: ready — press Start in the menu bar to begin coaching.")
        } else {
            jlog("Jarvis: no API key yet — paste it in Settings, then press Start.")
        }
    }

    /// Build the brain + driver and start the transcription pipeline. Returns `false` (and stays
    /// stopped) if no API key is available yet.
    ///
    /// `freshSession` is true for a user-initiated Start (rotate to a fresh dev session + logs) and
    /// false for an in-place restart that only re-applies a setting — e.g. saving a new API key while
    /// running — which must NOT be misattributed as a new coaching run.
    @discardableResult
    private func start(freshSession: Bool = true) -> Bool {
        guard let key = secrets.apiKey(), !key.isEmpty else {
            jlog("Jarvis: can't start — no API key.")
            warnNoKey()
            return false
        }
        stop() // tear down any existing pipeline so we start cleanly
        if freshSession {
            beginNewSession()       // dev mode: rotate to a fresh session dir + activity/debug log
            menuBar.resetCounter()  // a user Start begins a fresh session
        }

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
        // "Them" socket gave up: degrade gracefully — stop the system-audio transcriber and keep the
        // mic running. The shared aggregate capture keeps feeding the mic side; its now-nil "them"
        // transcriber simply drops the tap audio. The menu stays 🟢.
        let onThemTerminalFailure: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                self?.themTranscriber?.stop(); self?.themTranscriber = nil
                jlog("Jarvis: 'them' (system audio) socket gave up — mic side still active")
            }
        }

        // "Me" side: the mic. Drives turn-end and the backing-off silence check ("are you stuck?").
        let transcriber = RealtimeTranscriber(apiKey: key, model: config.transcriptionModel,
                                              speaker: .me, transcript: transcript, clock: clock,
                                              silenceTimeout: config.silenceTimeoutSeconds,
                                              silenceMaxInterval: config.silenceMaxIntervalSeconds,
                                              silenceDurationMs: config.vadSilenceDurationMs,
                                              noiseReduction: config.audioNoiseReduction,
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
                                                  noiseReduction: config.audioNoiseReduction,
                                                  turnDebounce: config.turnDebounceSeconds,
                                                  maxBufferedAudioSeconds: config.maxBufferedAudioSeconds)
        themTranscriber.onTurnEnd = { turns.run { await driver.handleTrigger(.turnEnd) } }
        themTranscriber.onTerminalFailure = onThemTerminalFailure

        // One-clock capture + echo cancellation: a single aggregate device (mic + system tap) feeds
        // the cleaned mic to the "me" socket and the raw system audio to the "them" socket, with AEC3
        // run inside its IOProc. If the device can't be built, the whole capture is gone, so treat it
        // as a full (mic-side) terminal failure.
        let capture = AggregateEchoCapture(
            onMicClean: { [weak transcriber] data in transcriber?.sendAudio(data) },
            onSystem: { [weak themTranscriber] data in themTranscriber?.sendAudio(data) })
        capture.onUnavailable = onMicTerminalFailure
        self.transcriber = transcriber
        self.themTranscriber = themTranscriber
        self.aggregateCapture = capture
        self.turns = turns
        transcriber.connect()
        themTranscriber.connect()
        capture.start()
        jlog("Jarvis: coaching started (one-clock capture + AEC).")
        return true
    }

    /// Stop and tear down the capture (one aggregate device) and BOTH transcription sockets
    /// (mic/"me" and system-audio/"them"). Safe to call when already stopped. The capture and both
    /// transcribers must go: otherwise a turn-end trigger from a still-live socket could drive a
    /// coaching turn on a torn-down driver — the exact "speak after Stop" failure the turns box exists
    /// to prevent — and a subsequent Start would leak the orphaned IOProc/sockets.
    private func stop() {
        let wasRunning = transcriber != nil || themTranscriber != nil
        turns?.cancelAll(); turns = nil      // cancel any in-flight coaching turn
        aggregateCapture?.stop(); aggregateCapture = nil   // stop the IOProc, tear down tap+aggregate
        transcriber?.stop()
        themTranscriber?.stop()
        transcriber = nil
        themTranscriber = nil
        if wasRunning { jlog("Jarvis: stopped.") }
    }


    private func warnNoKey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "No OpenAI API key set"
        alert.informativeText = "Open \u{201C}Settings\u{2026}\u{201D} from the Jarvis menu, paste your key, then press Start."
        alert.alertStyle = .informational
        alert.runModal()
    }

    /// Open a fresh dev session: a new per-Start subdirectory under the base log dir, with its own
    /// `jarvis-debug.log` and `jarvis-activity.jsonl`. Called on every Start so each coaching run keeps
    /// its own logs instead of resuming the previous run's. No-op outside dev mode.
    private func beginNewSession() {
        guard devMode else { return }
        let dir = devLogDirectory().appendingPathComponent(newSessionID())
        // 0700: the screenshots/logs inside are 0600, so the directory holding them must be owner-only
        // too — otherwise a 0755 dir leaks file names/counts/timestamps to other local users (CWE-732).
        // Applies to the created session dir and any intermediates.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        JarvisLog.enableFileLogging(directory: dir)     // <dir>/jarvis-debug.log, 0600, fresh
        ActivityLog.shared.enable(directory: dir)        // <dir>/jarvis-activity.jsonl, 0600, fresh
        // Point the viewer's history browser at the new current session and show it live; clear-history
        // spares whichever session is current.
        activityViewer?.sessionDidChange(base: devLogDirectory(), current: dir)
        jlog("Jarvis: dev mode — session \(dir.lastPathComponent) (\(dir.path)).")
    }

    /// A unique id for a dev session (one per Start), used as its log subdirectory name. Sortable
    /// timestamp + a short random suffix so two Starts in the same second don't collide.
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
    /// Each Start nests a per-session subdirectory under this base (see `beginNewSession`).
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
