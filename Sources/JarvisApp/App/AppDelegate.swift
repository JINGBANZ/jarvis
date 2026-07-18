import AppKit
import JarvisCore
import JarvisOverlay

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let clock = SystemClock()
    private let config = Config.default
    /// Recreated on every `start()`: the transcript must live and die with the driver/transcriber
    /// pair built there — they carry its [mm:ss] clock base and the driver's sent-index into it.
    private var transcript = RollingTranscript()
    private let secretFile = FileSecretStore()
    private lazy var secrets = ChainedSecretStore([secretFile, EnvSecretStore()])
    /// The single funnel for user-facing failures (alerts + fatal session teardown). See `ErrorReporter`.
    private let errorReporter = ErrorReporter()
    private let networkDiagnostics = NetworkPathDiagnostics()

    private var overlayCaption: OverlayCaptionPanel!   // transient on-screen tip
    private var overlayBox: OverlayBoxPanel!            // persistent, movable history of every spoken response
    private var menuBar: MenuBarController!
    private var settingsWindow: SettingsWindow!
    private let appearance = OverlayAppearance()
    private let brainPreferences = BrainPreferences()
    private let screenPreferences = ScreenCapturePreferences()
    private var activityViewer: ActivityViewer!    // embedded as the Settings Activity tab
    /// Two transcription sockets feeding one shared transcript: mic → `.me`, system audio → `.them`.
    private var transcriber: RealtimeTranscriber?       // "me" (mic)
    private var themTranscriber: RealtimeTranscriber?   // "them" (system audio)
    private var micConnectionState: RealtimeConnectionState = .stopped
    private var systemConnectionState: RealtimeConnectionState = .stopped
    private var reportedCoachingReady = false
    /// One-clock capture: a single private aggregate device (built-in mic + system-output tap on one
    /// drift-compensated clock) feeds both transcription sockets, running AEC3 inside its IOProc so the
    /// other side's speaker bleed is cancelled from the mic. Replaces the separate AVAudioEngine mic +
    /// ScreenCaptureKit capture.
    private var aggregateCapture: AggregateEchoCapture?
    /// In-flight coaching turns, so Stop can cancel one mid-brain-call (otherwise it could speak
    /// after the user pressed Stop).
    private var turns: TurnTaskBox?
    /// The global hint hotkey. Lives for the whole app run; its callback beeps when no session runs.
    private var hotkeys: HotkeyController?
    /// Fires an on-demand hint for the running session. Non-nil only while running — set in `start()`,
    /// cleared in `stop()` — so the hotkey beeps when there's no session. Captures the Sendable driver
    /// + turn box (not `@MainActor` self), like the transcriber callbacks do.
    private var requestManualHint: (() -> Void)?
    /// The current session's brain-traffic recorder, rotated by `beginNewSession` and handed to the
    /// clients built in `start()`. Per-session (not a shared singleton) on purpose: a request still
    /// unwinding when Stop → Start rotates sessions must record into the session that made it, not
    /// contaminate the new session's audit data.
    private var sessionTraffic: BrainTrafficLog?
    /// The current session's log directory (set by `beginNewSession`) — also where `CLIBrainClient`
    /// materializes screenshots for a CLI brain, keeping all screen-derived bytes in one owner-only place.
    private var currentSessionDir: URL?
    /// Stops whose cancelled turns haven't finished unwinding yet. Cancellation only *requests* the
    /// stop — an in-flight brain request unwinds asynchronously and records its final traffic line on
    /// the way out — so a just-stopped session isn't evaluable until its drain completes, or a quick
    /// Evaluate click would audit an incomplete `brain-traffic.jsonl`. A count (not a Bool) so a rapid
    /// Stop → Start → Stop can't have the first drain's completion unmask the second's.
    private var drainingStops = 0

    /// How many past session log *directories* to keep on disk; older ones are pruned at each Start so
    /// the always-on activity log stays bounded across launches. This caps session count, not the size
    /// of any one session — a very long single run still grows its (append-only) logs + screenshots.
    /// Clear all but the current via the viewer's "Clear history".
    private static let retainedSessions = 10

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar app, no Dock icon
        MainMenu.install() // an Edit menu so ⌘X/⌘C/⌘V/⌘A work in the Settings text fields
        networkDiagnostics.start()

        // The activity viewer lives for the whole app run, but a *session* is one coaching run: each
        // Start opens a fresh session dir + logs (see `beginNewSession`). No session exists until the
        // first Start, so the viewer starts with no current session to browse.
        activityViewer = ActivityViewer(log: .shared,
                                        store: SessionStore(base: logDirectory(), current: nil))
        // The one-click session evaluation: audit the recorded brain traffic with the selected brain
        // model at high effort (an audit is a depth task, not a latency one). Built at click time so
        // it always uses the current key/model; its own traffic is NOT recorded (`traffic` stays nil)
        // — the audit must not pollute the session it audits.
        activityViewer.makeEvaluator = { [weak self] in
            guard let self else { return nil }
            let provider = self.brainPreferences.provider
            if provider.usesLocalCLI {
                guard let cli = AgentCLIDetector().detect(provider) else { return nil }
                let brain = CLIBrainClient(provider: provider, executable: cli.executableURL,
                                           model: self.brainPreferences.model(for: provider).id,
                                           reasoningEffort: ReasoningEffort.high.rawValue,
                                           workDirectory: self.currentSessionDir ?? self.logDirectory(),
                                           timeout: 600)   // a big session transcript takes minutes, not seconds
                return SessionEvaluator(brain: brain)
            }
            guard let key = self.secrets.apiKey(), !key.isEmpty else { return nil }
            let brain = OpenAIBrainClient(apiKey: key, model: self.brainPreferences.model.id,
                                          reasoningEffort: ReasoningEffort.high.rawValue,
                                          timeout: 300,   // a big session transcript takes minutes, not seconds
                                          maxOutputTokens: ReasoningEffort.high.maxOutputTokens,
                                          promptCacheKey: "jarvis-eval-v1")
            return SessionEvaluator(brain: brain)
        }
        // Evaluation is for finished conversations only: the viewer disables its Evaluate button for
        // the live session while coaching runs — or while a cancelled turn is still draining its
        // final traffic line (start()/stop() ping it via coachingStateDidChange).
        activityViewer.isCoachingRunning = { [weak self] in
            guard let self else { return false }
            return self.transcriber != nil || self.drainingStops > 0
        }

        // Ask for Microphone + Screen Recording up front, not lazily mid-session.
        Permissions.primeAll()

        overlayCaption = OverlayCaptionPanel()
        overlayCaption.setFontSize(appearance.captionFontSize)
        overlayCaption.setBackgroundOpacity(appearance.captionBackgroundOpacity)
        overlayCaption.setEnabled(appearance.captionEnabled)   // off by default

        overlayBox = OverlayBoxPanel()
        overlayBox.setFontSize(appearance.boxFontSize)
        overlayBox.setOpacity(appearance.boxOpacity)
        overlayBox.setEnabled(appearance.boxEnabled)   // on by default — shows the history box at launch

        menuBar = MenuBarController()

        // Unified Settings window: brain (provider + model + API key) + overlay appearance + the
        // activity log. A pasted key is stored but does not auto-start; restart only if already
        // running, reflecting the real outcome back into the menu state.
        let sections: [SettingsSection] = [
            BrainSection(preferences: brainPreferences, detector: AgentCLIDetector(),
                         keyStore: secretFile, onKeySaved: { [weak self] _ in
                guard let self, self.transcriber != nil else { return }
                // Re-saving a key while running only re-applies it to the pipeline — it is NOT a new
                // coaching run, so keep the current session (don't rotate logs). Session rotation is
                // reserved for an explicit user Start.
                self.start(freshSession: false)
            }),
            OverlaySection(appearance: appearance, caption: overlayCaption, box: overlayBox),
            DisplaySection(preferences: screenPreferences),
            ActivitySection(viewer: activityViewer),
        ]
        settingsWindow = SettingsWindow(sections: sections)
        menuBar.onOpenSettings = { [weak self] in self?.settingsWindow.show() }

        // The menu drives the pipeline lifecycle. Jarvis does NOT auto-start; the user presses Start.
        menuBar.onStart = { [weak self] in self?.start() ?? false }
        menuBar.onStop = { [weak self] in self?.stop() }

        // A fatal error tears the session down and corrects the menu — one place owns that.
        errorReporter.onFatal = { [weak self] in
            self?.stop()
        }

        // Global hint hotkey: while a session is running, screenshot + ask the brain for a hint in one
        // trip; otherwise beep — there's no live driver/conversation to hint from when stopped.
        hotkeys = HotkeyController()
        hotkeys?.onRequestHint = { [weak self] in
            guard let self, let fire = self.requestManualHint else { NSSound.beep(); return }
            fire()
        }

        if secrets.apiKey()?.isEmpty == false {
            jlog("Jarvis: ready — press Start in the menu bar to begin coaching.")
        } else {
            jlog("Jarvis: no API key yet — paste it in Settings, then press Start.")
        }
    }

    /// Build the brain + driver and start the transcription pipeline. Returns `false` (and stays
    /// stopped) if no API key is available yet (transcription always needs it), or if the selected
    /// brain provider's CLI is missing.
    ///
    /// `freshSession` is true for a user-initiated Start (rotate to a fresh session + logs) and
    /// false for an in-place restart that only re-applies a setting — e.g. saving a new API key while
    /// running — which must NOT be misattributed as a new coaching run.
    @discardableResult
    private func start(freshSession: Bool = true) -> Bool {
        guard let key = secrets.apiKey(), !key.isEmpty else {
            jlog("Jarvis: can't start — no API key.")
            errorReporter.report(.noAPIKey)
            return false
        }
        // A CLI brain provider's binary must exist before anything is torn down — a failed Start
        // must leave the app exactly as it was.
        let brainProvider = brainPreferences.provider
        var brainCLI: DetectedAgentCLI?
        if brainProvider.usesLocalCLI {
            guard let cli = AgentCLIDetector().detect(brainProvider) else {
                jlog("Jarvis: can't start — \(brainProvider.displayName) CLI not found.")
                errorReporter.report(.brainCLIMissing(provider: brainProvider.displayName))
                return false
            }
            switch cli.authenticationStatus {
            case .signedIn:
                break
            case .signedOut:
                jlog("Jarvis: can't start — \(brainProvider.displayName) isn't signed in.")
                errorReporter.report(.brainCLINotSignedIn(provider: brainProvider.displayName))
                return false
            case .unknown:
                errorReporter.report(.brainCLISignInUnconfirmed(provider: brainProvider.displayName))
            }
            brainCLI = cli
        }
        stop() // tear down any existing pipeline so we start cleanly
        // A fresh transcript for the fresh pipeline (even on an in-place restart, which rebuilds the
        // driver and transcribers too). Reusing the old one would re-send a dead run's lines as "new
        // since last turn" — their [mm:ss] stamps minted against the previous transcriber's clock —
        // and anchor the silence math to that run's last utterance instead of real quiet time.
        transcript = RollingTranscript()
        if freshSession {
            beginNewSession()  // rotate to a fresh session dir + activity/debug log
            overlayBox.clear() // …and a fresh response history for the new conversation
        }

        // Both clients record their wire traffic into the session's `brain-traffic.jsonl` (enabled in
        // `beginNewSession`), tagged so the evaluation can tell the coach and summarizer apart. The
        // recording sits INSIDE the retry wrapper, so each retry attempt is its own audit-visible entry.
        // History-compaction summaries don't need the coaching model — each provider's cheap tier
        // (see `BrainModelCatalog.summarizerModelID`) writes a 250-word briefing a few times an hour.
        let coachBase: BrainClient
        let summarizer: BrainClient
        if let cli = brainCLI {
            // Brain on the local CLI: turns are billed to the user's Claude/ChatGPT subscription.
            // Screenshots for the CLI are materialized inside the session dir (owner-only posture).
            let sessionDir = currentSessionDir ?? logDirectory()
            coachBase = CLIBrainClient(provider: brainProvider, executable: cli.executableURL,
                                       model: brainPreferences.model(for: brainProvider).id,
                                       reasoningEffort: brainPreferences.effort.rawValue,
                                       workDirectory: sessionDir,
                                       traffic: sessionTraffic, trafficTag: "coach")
            summarizer = CLIBrainClient(provider: brainProvider, executable: cli.executableURL,
                                        model: BrainModelCatalog.summarizerModelID(for: brainProvider),
                                        reasoningEffort: ReasoningEffort.low.rawValue,
                                        workDirectory: sessionDir,
                                        traffic: sessionTraffic, trafficTag: "summarizer")
        } else {
            coachBase = OpenAIBrainClient(apiKey: key, model: brainPreferences.model.id,
                                          reasoningEffort: brainPreferences.effort.rawValue,
                                          maxOutputTokens: brainPreferences.effort.maxOutputTokens,
                                          traffic: sessionTraffic, trafficTag: "coach")
            summarizer = OpenAIBrainClient(apiKey: key, model: BrainModelCatalog.summarizerModelID(for: .openAI),
                                           reasoningEffort: ReasoningEffort.low.rawValue,
                                           maxOutputTokens: 2_048,
                                           traffic: sessionTraffic, trafficTag: "summarizer")
        }
        let brain = RetryingBrainClient(base: coachBase)
        // A token can expire after the bounded Start preflight, and other runtime failures remain
        // possible. If the actual CLI request fails, surface the reason and stop the green-but-
        // unusable session instead of silently ignoring every later utterance.
        let onBrainFailure: (@Sendable (String) -> Void)?
        if brainProvider.usesLocalCLI {
            let signInCommand = brainProvider == .claudeCode ? "claude auth login" : "codex login"
            onBrainFailure = { [errorReporter] reason in
                // Preserve ghost mode: the fixed Activity notice is enough for the human-facing
                // record; the provider's detailed failure stays in jarvis-debug.log below.
                ActivityLog.shared.record(.coachingStopped(provider: brainProvider))
                errorReporter.report(.brainCLIStopped(provider: brainProvider.displayName,
                                                       signInCommand: signInCommand,
                                                       reason: reason))
            }
        } else {
            onBrainFailure = nil
        }
        // Fan each spoken tip out to both the Overlay Caption and the persistent Overlay Box.
        let overlaySink = BroadcastOverlay([overlayCaption, overlayBox])
        let driver = CoachDriver(config: config, transcript: transcript,
                                 brain: brain, summarizer: summarizer,
                                 screen: WindowScopedScreenCapture(preferences: screenPreferences),
                                 overlay: overlaySink, clock: clock,
                                 onBrainFailure: onBrainFailure)

        // CoachDriver is @unchecked Sendable; capture it (not @MainActor self) in the callbacks.
        // Route turns through TurnTaskBox so Stop can cancel an in-flight one. Concurrent triggers are
        // coalesced inside CoachDriver (the running turn batches them in), so we don't cancel here.
        let turns = TurnTaskBox()
        // Mic socket gave up (bad key / quota / network): coaching can't continue. Report fatal — the
        // reporter's onFatal stops the session and corrects the menu (no more lying 🟢).
        let onMicTerminalFailure: @Sendable () -> Void = { [errorReporter] in
            errorReporter.report(.transcriptionStopped)
        }
        // "Them" socket gave up: degrade gracefully — stop the system-audio transcriber, keep the mic
        // running. The shared aggregate capture keeps feeding the mic side; its now-nil "them"
        // transcriber simply drops the tap audio. Still report it (a non-blocking .degraded notice) so
        // it flows through the one funnel; the menu stays 🟢.
        let onThemTerminalFailure: @Sendable () -> Void = { [weak self, errorReporter] in
            Task { @MainActor in
                guard let self else { return }
                self.themTranscriber?.stop()
                self.themTranscriber = nil
                // The transcriber's asynchronous `.stopped` callback is identity-guarded and will
                // be ignored after nil-ing it, so commit the degraded state explicitly here.
                self.systemConnectionState = .failed
                self.refreshConnectionUI()
            }
            errorReporter.report(.systemAudioStopped)
        }

        // "Me" side: the mic. Drives turn-end and the backing-off silence check ("are you stuck?").
        let transcriber = RealtimeTranscriber(apiKey: key, model: config.transcriptionModel,
                                              speaker: .me, transcript: transcript, clock: clock,
                                              silenceTimeout: config.silenceTimeoutSeconds,
                                              silenceMaxInterval: config.silenceMaxIntervalSeconds,
                                              silenceIdleCutoff: config.silenceIdleCutoffSeconds,
                                              silenceDurationMs: config.vadSilenceDurationMs,
                                              noiseReduction: config.audioNoiseReduction,
                                              turnDebounce: config.turnDebounceSeconds,
                                              maxBufferedAudioSeconds: config.maxBufferedAudioSeconds,
                                              readyTimeout: config.realtimeReadyTimeoutSeconds,
                                              pingInterval: config.realtimePingIntervalSeconds,
                                              pongTimeout: config.realtimePongTimeoutSeconds,
                                              networkStatus: { [networkDiagnostics] in
                                                  networkDiagnostics.currentSummary
                                              })
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
                                                  maxBufferedAudioSeconds: config.maxBufferedAudioSeconds,
                                                  readyTimeout: config.realtimeReadyTimeoutSeconds,
                                                  pingInterval: config.realtimePingIntervalSeconds,
                                                  pongTimeout: config.realtimePongTimeoutSeconds,
                                                  networkStatus: { [networkDiagnostics] in
                                                      networkDiagnostics.currentSummary
                                                  })
        themTranscriber.onTurnEnd = { turns.run { await driver.handleTrigger(.turnEnd) } }
        themTranscriber.onTerminalFailure = onThemTerminalFailure

        // One-clock capture + echo cancellation: a single aggregate device (mic + system tap) feeds
        // the cleaned mic to the "me" socket and the sample-preserving system timeline to the "them"
        // socket, with AEC3 run inside its IOProc. If the device can't be built, the whole capture is
        // gone, so treat it as a full (mic-side) terminal failure.
        let capture = AggregateEchoCapture(
            onMicCaptured: { [weak transcriber] sequence, samples, capturedAt in
                transcriber?.recordCapturedAudio(
                    sequenceNumber: sequence, sampleCount: samples, capturedAt: capturedAt)
            },
            onSystemCaptured: { [weak themTranscriber] sequence, samples, capturedAt in
                themTranscriber?.recordCapturedAudio(
                    sequenceNumber: sequence, sampleCount: samples, capturedAt: capturedAt)
            },
            onMicClean: { [weak transcriber] data, sequence, capturedAt in
                transcriber?.sendAudio(
                    data, sequenceNumber: sequence, capturedAt: capturedAt)
            },
            onSystem: { [weak themTranscriber] data, sequence, capturedAt in
                themTranscriber?.sendAudio(
                    data, sequenceNumber: sequence, capturedAt: capturedAt)
            })
        capture.onUnavailable = { [errorReporter] reason in
            errorReporter.report(.captureFailed(reason: reason))
        }
        self.transcriber = transcriber
        self.themTranscriber = themTranscriber
        self.aggregateCapture = capture
        self.turns = turns
        micConnectionState = .connecting
        systemConnectionState = .connecting
        reportedCoachingReady = false
        menuBar.setState(.starting)
        transcriber.onConnectionStateChange = { [weak self, weak transcriber] state in
            guard let transcriber else { return }
            Task { @MainActor [weak self] in
                guard let self, self.transcriber === transcriber else { return }
                self.micConnectionState = state
                self.refreshConnectionUI()
            }
        }
        themTranscriber.onConnectionStateChange = { [weak self, weak themTranscriber] state in
            guard let themTranscriber else { return }
            Task { @MainActor [weak self] in
                guard let self, self.themTranscriber === themTranscriber else { return }
                self.systemConnectionState = state
                self.refreshConnectionUI()
            }
        }
        // Arm the hint hotkey for this session: capture the screen and force a one-trip hint, routed
        // through the same turn box as audio triggers (so Stop cancels it and rapid presses coalesce).
        self.requestManualHint = { turns.run { await driver.handleTrigger(.manualHint) } }
        transcriber.connect()
        themTranscriber.connect()
        if let reason = capture.start() {
            stop()                      // tear down the sockets we just opened
            errorReporter.report(.captureFailed(reason: reason))
            return false
        }
        jlog("Jarvis: coaching starting — verifying realtime transcription connections.")
        jlog("Jarvis network path at start: \(networkDiagnostics.currentSummary)")
        activityViewer.coachingStateDidChange()   // the live session is no longer evaluable
        return true
    }

    /// Stop and tear down the capture (one aggregate device) and BOTH transcription sockets
    /// (mic/"me" and system-audio/"them"). Safe to call when already stopped. The capture and both
    /// transcribers must go: otherwise a turn-end trigger from a still-live socket could drive a
    /// coaching turn on a torn-down driver — the exact "speak after Stop" failure the turns box exists
    /// to prevent — and a subsequent Start would leak the orphaned IOProc/sockets.
    private func stop() {
        let wasRunning = transcriber != nil || themTranscriber != nil
        requestManualHint = nil              // hotkey beeps again once there's no live session
        let cancelled = turns?.cancelAll() ?? []; turns = nil   // cancel any in-flight coaching turn
        // Mark both delivery endpoints stopped before draining the IOProc. Aggregate capture hands
        // chunks off asynchronously, so callbacks already queued during teardown must see the
        // transcribers' stopped guards and become no-ops.
        transcriber?.stop()
        themTranscriber?.stop()
        aggregateCapture?.stop(); aggregateCapture = nil   // stop the IOProc, tear down tap+aggregate
        transcriber = nil
        themTranscriber = nil
        micConnectionState = .stopped
        systemConnectionState = .stopped
        reportedCoachingReady = false
        menuBar?.setState(.stopped)
        if wasRunning { jlog("Jarvis: stopped.") }
        // The just-stopped session becomes evaluable only once any cancelled turn has actually
        // finished unwinding — its brain request records a final traffic line on the way out, and an
        // Evaluate click before that line lands would audit an incomplete brain-traffic.jsonl.
        if !cancelled.isEmpty {
            drainingStops += 1
            Task { @MainActor [weak self] in
                for task in cancelled { await task.value }
                guard let self else { return }
                self.drainingStops -= 1
                self.activityViewer?.coachingStateDidChange()
            }
        }
        activityViewer?.coachingStateDidChange()
    }

    /// The mic socket is the truth for whether Jarvis is listening. System audio may reconnect or
    /// fail independently; that degrades the other side of a call without pretending the mic is down.
    private func refreshConnectionUI() {
        guard transcriber != nil else {
            menuBar.setState(.stopped)
            return
        }
        switch micConnectionState {
        case .connecting:
            menuBar.setState(.starting)
        case .reconnecting(let attempt):
            menuBar.setState(.reconnecting(attempt: attempt))
        case .ready:
            if systemConnectionState == .ready {
                menuBar.setState(.listening)
                if !reportedCoachingReady {
                    reportedCoachingReady = true
                    jlog("Jarvis: coaching ready (mic + system audio).")
                }
            } else if systemConnectionState == .failed || systemConnectionState == .stopped {
                menuBar.setState(.microphoneOnly)
            } else {
                menuBar.setState(.systemAudioConnecting)
            }
        case .failed:
            // `onTerminalFailure` immediately routes through ErrorReporter and stops the session.
            menuBar.setState(.reconnecting(attempt: 6))
        case .stopped:
            menuBar.setState(.stopped)
        }
    }


    /// Open a fresh session: a new per-Start subdirectory under the base log dir, with its own
    /// `jarvis-debug.log` and `jarvis-activity.jsonl`. Called on every Start so each coaching run keeps
    /// its own logs instead of resuming the previous run's.
    private func beginNewSession() {
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
        JarvisLog.enableFileLogging(directory: dir)     // <dir>/jarvis-debug.log, 0600, fresh
        ActivityLog.shared.enable(directory: dir)        // <dir>/jarvis-activity.jsonl, 0600, fresh
        let traffic = BrainTrafficLog()                  // fresh recorder BOUND to this session's dir
        traffic.enable(directory: dir)                   // <dir>/brain-traffic.jsonl, 0600, fresh
        sessionTraffic = traffic
        currentSessionDir = dir
        // Now that logging is always on, sessions accumulate every launch. Bound it: keep only the most
        // recent few (the just-created one is current, so it's always spared).
        SessionStore(base: base, current: dir).pruneToMostRecent(Self.retainedSessions)
        // Point the viewer's history browser at the new current session and show it live; clear-history
        // spares whichever session is current.
        activityViewer.sessionDidChange(base: base, current: dir)
        jlog("Jarvis: session \(dir.lastPathComponent) (\(dir.path)).")
    }

    /// A unique id for a session (one per Start), used as its log subdirectory name. Sortable
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

    /// Where session logs go. `build-app.sh --run` passes a `--log-dir` pointing at the repo's
    /// gitignored, workspace-local `.jarvis/` (the app is launched by `open` from an arbitrary cwd, so
    /// it can't find the repo itself). When the bundle is opened directly with no `--log-dir`, fall back
    /// to a per-user app-data dir alongside the API key — `~/Library/Application Support/Jarvis/sessions/`
    /// — which is always writable and owner-only. Each Start nests a per-session subdir under this base
    /// (see `beginNewSession`).
    private func logDirectory() -> URL {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--log-dir"), i + 1 < args.count {
            return URL(fileURLWithPath: args[i + 1])
        }
        return secretFile.fileURL.deletingLastPathComponent().appendingPathComponent("sessions")
    }
}
