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
    private var brainSection: BrainSection!
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
    private var reportedTranscriptionFailure = false
    /// One-clock capture: a single private aggregate device (built-in mic + system-output tap on one
    /// drift-compensated clock) feeds both transcription sockets, running AEC3 inside its IOProc so the
    /// other side's speaker bleed is cancelled from the mic. Replaces the separate AVAudioEngine mic +
    /// ScreenCaptureKit capture.
    private var aggregateCapture: AggregateEchoCapture?
    /// In-flight coaching turns, so Stop can cancel one mid-brain-call (otherwise it could speak
    /// after the user pressed Stop).
    private var turns: TurnTaskBox?
    /// The running session's event loop. Stored so Brain Settings can replace only its model clients
    /// without restarting transcription or discarding the session's transcript/history.
    private var coachDriver: CoachDriver?
    /// Runtime route state for truthful Settings and Activity updates. A Settings edit is announced
    /// only when the replacement route actually selects its first target for a fresh attempt.
    private var activeBrainTarget: BrainTarget?
    private var pendingBrainChangeFrom: BrainTarget?
    /// A Start that is still discovering local CLIs. Stop or a newer Start cancels it before the
    /// prepared runtime can be installed on the main actor.
    private var pendingStartTask: Task<Void, Never>?
    private var pendingStartRevision: UInt = 0
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
        NSApp.setActivationPolicy(.accessory) // ghost-mode-allowed: launch configuration
        MainMenu.install() // an Edit menu so ⌘X/⌘C/⌘V/⌘A work in the Settings text fields
        networkDiagnostics.start()

        // Before this release OpenAI was an implicit primary, so a usable existing installation may
        // have a transcription key but no persisted provider key. Preserve that legacy selection.
        // A genuinely untouched install has neither and remains unconfigured for the first-open UI.
        if brainPreferences.configuredPrimaryTarget == nil,
           secrets.apiKey()?.isEmpty == false {
            brainPreferences.provider = .openAI
        }

        // The activity viewer lives for the whole app run, but a *session* is one coaching run: each
        // Start opens a fresh session dir + logs (see `beginNewSession`). No session exists until the
        // first Start, so the viewer starts with no current session to browse.
        activityViewer = ActivityViewer(log: .shared,
                                        store: SessionStore(base: logDirectory(), current: nil))
        // Evaluation/report opening is explicit Activity UI and remains unavailable while coaching
        // runs—or while a cancelled turn is still draining—so it cannot reveal Jarvis during the
        // ghost lifecycle.
        activityViewer.isCoachingRunning = { [weak self] in
            guard let self else { return false }
            return self.transcriber != nil || self.drainingStops > 0
        }
        // The button launches the same sole agentic evaluator as scripts/eval-session.sh. Resolve the
        // checkout at click time and read the current provider preference then, so Settings changes
        // and a moved local app bundle are both reflected without rebuilding Activity.
        activityViewer.makeEvaluator = { [weak self] in
            guard let self, let repository = self.evaluationRepositoryDirectory() else { return nil }
            return AgenticEvaluator(repositoryDirectory: repository,
                                    preferredProvider: self.brainPreferences.provider)
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
        // activity log. A pasted key is stored but does not auto-start. While running, it updates
        // future Realtime connections and transactionally replaces only an OpenAI brain—never the
        // capture/transcript pipeline.
        brainSection = BrainSection(
            preferences: brainPreferences,
            detector: AgentCLIDetector(),
            onPreferencesChanged: { [weak self] change, clis in
                self?.applyBrainPreferencesToRunningSession(
                    detectedCLIs: clis,
                    update: change == .topology ? .topologyEdit : .effortEdit)
            },
            keyStore: secretFile,
            onKeySaved: { [weak self] key in
                self?.applySavedAPIKeyToRunningSession(key)
            })
        let sections: [SettingsSection] = [
            brainSection,
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
            guard let self, let fire = self.requestManualHint else {
                NSSound.beep() // ghost-mode-allowed: explicit user hotkey while stopped
                return
            }
            fire()
        }

        if secrets.apiKey()?.isEmpty == false {
            jlog("Jarvis: ready — press Start in the menu bar to begin coaching.")
        } else {
            jlog("Jarvis: no API key yet — paste it in Settings, then press Start.")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        activityViewer?.cancelEvaluation()
    }

    /// The two clients that move together with one provider/model route target.
    private struct BrainRuntime {
        let coach: BrainClient
        let summarizer: BrainClient
    }

    /// Check the selected local provider before disturbing a live session. OpenAI needs no provider
    /// preflight; a missing/signed-out CLI leaves the current brain intact and reports fixed Activity
    /// copy while raw detection detail stays in the debug log.
    private func preflightBrainProvider(_ provider: BrainProvider,
                                        detectedCLI: DetectedAgentCLI?,
                                        context: UserFacingError.PresentationContext,
                                        recordSettingsFailure: Bool)
        -> (isReady: Bool, cli: DetectedAgentCLI?) {
        guard provider.usesLocalCLI else { return (true, nil) }
        let action = recordSettingsFailure ? "apply brain settings" : "start"
        guard let cli = detectedCLI else {
            jlog("Jarvis: can't \(action) — \(provider.displayName) CLI not found.")
            if recordSettingsFailure { ActivityLog.shared.record(.settingsChangeNotApplied) }
            errorReporter.reportImmediately(
                .brainCLIMissing(provider: provider.displayName), context: context)
            return (false, nil)
        }
        switch cli.authenticationStatus {
        case .signedIn:
            break
        case .signedOut:
            jlog("Jarvis: can't \(action) — \(provider.displayName) isn't signed in.")
            if recordSettingsFailure { ActivityLog.shared.record(.settingsChangeNotApplied) }
            errorReporter.reportImmediately(
                .brainCLINotSignedIn(provider: provider.displayName), context: context)
            return (false, nil)
        case .unknown:
            errorReporter.reportImmediately(
                .brainCLISignInUnconfirmed(provider: provider.displayName), context: context)
        }
        return (true, cli)
    }

    /// Construct the coach + compaction clients for one preferences snapshot. Both keep writing to
    /// the current session's traffic recorder, so a hot switch remains one auditable conversation.
    private func makeBrainRuntime(
        apiKey key: String,
        target: BrainTarget,
        effort: ReasoningEffort,
        cli: DetectedAgentCLI?
    ) -> BrainRuntime {
        let coachBase: BrainClient
        let summarizer: BrainClient
        if let cli {
            let sessionDir = currentSessionDir ?? logDirectory()
            coachBase = CLIBrainClient(provider: target.provider, executable: cli.executableURL,
                                       model: target.modelID,
                                       reasoningEffort: effort.rawValue,
                                       workDirectory: sessionDir,
                                       codexSupportedFeatures: cli.supportedFeatures,
                                       traffic: sessionTraffic, trafficTag: "coach")
            summarizer = CLIBrainClient(provider: target.provider, executable: cli.executableURL,
                                        model: BrainModelCatalog.summarizerModelID(for: target.provider),
                                        reasoningEffort: ReasoningEffort.low.rawValue,
                                        workDirectory: sessionDir,
                                        codexSupportedFeatures: cli.supportedFeatures,
                                        traffic: sessionTraffic, trafficTag: "summarizer")
        } else {
            coachBase = OpenAIBrainClient(
                apiKey: key, model: target.modelID,
                reasoningEffort: effort.rawValue,
                maxOutputTokens: effort.maxOutputTokens,
                traffic: sessionTraffic, trafficTag: "coach")
            summarizer = OpenAIBrainClient(
                apiKey: key, model: BrainModelCatalog.summarizerModelID(for: .openAI),
                reasoningEffort: ReasoningEffort.low.rawValue, maxOutputTokens: 2_048,
                traffic: sessionTraffic, trafficTag: "summarizer")
        }
        return BrainRuntime(coach: coachBase, summarizer: summarizer)
    }

    /// Missing or definitively signed-out fallback CLIs remain in the runtime route as unavailable
    /// entries. The driver skips them only if the session cursor reaches them.
    private func fallbackUnavailability(
        for target: BrainTarget,
        detectedCLI: DetectedAgentCLI?
    ) -> String? {
        guard target.provider.usesLocalCLI else { return nil }
        guard let detectedCLI else {
            return "\(target.provider.displayName) CLI was not found"
        }
        if detectedCLI.authenticationStatus == .signedOut {
            return "\(target.provider.displayName) is signed out"
        }
        return nil
    }

    private func makeConfiguredRoute(
        _ route: BrainRoute,
        detectedCLIs: [BrainProvider: DetectedAgentCLI],
        apiKey key: String,
        effort: ReasoningEffort,
        sessionDirectory: URL
    ) -> ConfiguredBrainRoute {
        let targets = route.targets.map { target -> ConfiguredBrainTarget in
            let cli = detectedCLIs[target.provider]
            if let detail = fallbackUnavailability(for: target, detectedCLI: cli) {
                return ConfiguredBrainTarget(unavailable: target, detail: detail)
            }
            let runtime = makeBrainRuntime(
                apiKey: key, target: target, effort: effort, cli: cli)
            return ConfiguredBrainTarget(
                target: target, brain: runtime.coach, summarizer: runtime.summarizer)
        }

        return ConfiguredBrainRoute(
            targets: targets,
            onSelected: { [weak self] target in
                guard let self, self.coachDriver != nil,
                      self.currentSessionDir == sessionDirectory else {
                    jlog("Jarvis: ignoring target selection from a stopped or superseded session.")
                    return
                }
                if let previous = self.pendingBrainChangeFrom {
                    ActivityLog.shared.record(.brainChangeApplied(
                        previous: previous.provider,
                        current: target.provider))
                    self.pendingBrainChangeFrom = nil
                }
                self.activeBrainTarget = target
                self.brainSection.setActiveTarget(target)
            },
            onAdvanced: { [weak self] previous, current in
                guard let self, self.coachDriver != nil,
                      self.currentSessionDir == sessionDirectory else {
                    jlog("Jarvis: ignoring route transition from a stopped or superseded session.")
                    return
                }
                ActivityLog.shared.record(.brainRouteAdvanced(
                    previous: previous.provider, current: current.provider))
            },
            onSkipped: { [weak self] target in
                guard let self, self.coachDriver != nil,
                      self.currentSessionDir == sessionDirectory else {
                    jlog("Jarvis: ignoring unavailable-target notice from a stopped session.")
                    return
                }
                ActivityLog.shared.record(
                    .brainRouteTargetSkipped(provider: target.provider))
            },
            onExhausted: { [weak self, errorReporter] target, failure in
                guard let self, self.coachDriver != nil,
                      self.currentSessionDir == sessionDirectory else {
                    jlog("Jarvis: ignoring route exhaustion from a stopped or superseded session.")
                    return
                }
                ActivityLog.shared.record(
                    .brainRouteExhausted(lastProvider: target.provider))
                errorReporter.reportImmediately(
                    .brainRouteExhausted(
                        lastProvider: target.provider.displayName,
                        reason: failure.detail),
                    context: .runtime)
            })
    }

    private enum RunningBrainUpdate: Equatable {
        case topologyEdit
        case effortEdit
        case credentialRefresh
    }

    /// Apply provider/model topology or effort changes without touching capture, transcription,
    /// history, or the session directory. An in-flight turn finishes on its old client snapshot.
    private func applyBrainPreferencesToRunningSession(
        detectedCLIs: [BrainProvider: DetectedAgentCLI]?,
        apiKeyOverride: String? = nil,
        update: RunningBrainUpdate
    ) {
        guard let coachDriver, transcriber != nil, let sessionDirectory = currentSessionDir else {
            return
        }
        guard let key = apiKeyOverride ?? secrets.apiKey(), !key.isEmpty else {
            jlog("Jarvis: can't apply brain settings — no API key.")
            ActivityLog.shared.record(.settingsChangeNotApplied)
            return
        }
        guard let route = brainPreferences.configuredRoute else {
            jlog("Jarvis: can't apply brain settings — no primary provider.")
            ActivityLog.shared.record(.settingsChangeNotApplied)
            return
        }
        let provider = route.primary.provider
        var readyCLIs = detectedCLIs ?? [:]
        if update == .topologyEdit {
            let preflight = preflightBrainProvider(
                provider, detectedCLI: detectedCLIs?[provider], context: .runtime,
                                                   recordSettingsFailure: true)
            guard preflight.isReady else { return }
            if let cli = preflight.cli {
                readyCLIs[provider] = cli
            }
        }
        let configuredRoute = makeConfiguredRoute(
            route,
            detectedCLIs: readyCLIs,
            apiKey: key,
            effort: brainPreferences.effort,
            sessionDirectory: sessionDirectory)
        switch update {
        case .topologyEdit:
            if pendingBrainChangeFrom == nil {
                pendingBrainChangeFrom = activeBrainTarget
            }
            coachDriver.updateBrainRoute(configuredRoute)
            let model = route.primary.model ?? BrainModelCatalog.defaultModel(for: provider)
            jlog("Jarvis: brain settings will apply on the next turn — \(provider.displayName), "
                 + "\(model.displayName), \(brainPreferences.effort.displayName) effort.")
        case .effortEdit:
            if pendingBrainChangeFrom == nil {
                pendingBrainChangeFrom = activeBrainTarget
            }
            guard coachDriver.reconfigureBrainRouteClients(configuredRoute) else {
                jlog("Jarvis: skipped stale effort refresh after the route topology changed.")
                return
            }
            jlog("Jarvis: reasoning effort will apply on the next coaching attempt.")
        case .credentialRefresh:
            guard coachDriver.refreshBrainRouteClients(configuredRoute, for: [.openAI]) else {
                jlog("Jarvis: skipped stale API-key brain refresh after the route topology changed.")
                return
            }
            jlog("Jarvis: saved API key will apply to OpenAI on the next coaching attempt.")
        }
    }

    /// Keep a healthy live conversation intact when the credential file changes. Existing Realtime
    /// sockets are already authenticated; retain them and use the new key only if either socket later
    /// reconnects. If OpenAI is in the selected brain route, install fresh target clients between
    /// coaching attempts without changing the route policy or restarting transcription.
    private func applySavedAPIKeyToRunningSession(_ key: String) {
        guard let transcriber else { return }
        transcriber.updateAPIKey(key)
        themTranscriber?.updateAPIKey(key)
        guard let route = brainPreferences.configuredRoute,
              route.targets.contains(where: { $0.provider == .openAI }) else {
            jlog("Jarvis: saved API key will apply to future Realtime connections.")
            return
        }
        applyBrainPreferencesToRunningSession(
            detectedCLIs: nil,
            apiKeyOverride: key,
            update: .credentialRefresh)
    }

    /// Validate a Start immediately, then prepare any local-CLI targets away from the main actor.
    /// Returns `true` once startup is accepted; the menu remains in Starting until preparation and
    /// the Realtime connections finish. Stop, a newer Start, a key change, or a route edit makes the
    /// prepared result stale before it can install a pipeline.
    @discardableResult
    private func start() -> Bool {
        let wasRunning = transcriber != nil || themTranscriber != nil
        let reportContext: UserFacingError.PresentationContext =
            wasRunning ? .runtime : .startup
        guard let key = secrets.apiKey(), !key.isEmpty else {
            jlog("Jarvis: can't start — no API key.")
            if wasRunning {
                ActivityLog.shared.record(.settingsChangeNotApplied)
            }
            errorReporter.reportImmediately(.noAPIKey, context: reportContext)
            return false
        }
        guard let brainRoute = brainPreferences.configuredRoute else {
            jlog("Jarvis: can't start — no primary provider.")
            if wasRunning {
                ActivityLog.shared.record(.settingsChangeNotApplied)
            }
            errorReporter.reportImmediately(
                .brainProviderNotConfigured, context: reportContext)
            return false
        }

        pendingStartRevision &+= 1
        let revision = pendingStartRevision
        pendingStartTask?.cancel()
        pendingStartTask = nil
        let cliProviders = brainRoute.targets.map(\.provider).filter(\.usesLocalCLI)
        guard !cliProviders.isEmpty else {
            return installPreparedStart(
                apiKey: key,
                brainRoute: brainRoute,
                detectedCLIs: [:],
                wasRunning: wasRunning,
                reportContext: reportContext)
        }

        menuBar.setState(.starting)
        let detector = AgentCLIDetector()
        pendingStartTask = Task { [weak self] in
            let detected = await detector.detectAllAsync(cliProviders)
            guard let self, !Task.isCancelled,
                  self.pendingStartRevision == revision else {
                return
            }
            guard self.secrets.apiKey() == key,
                  self.brainPreferences.configuredRoute == brainRoute else {
                self.pendingStartTask = nil
                self.refreshConnectionUI()
                return
            }
            self.pendingStartTask = nil
            let detectedCLIs = Dictionary(
                uniqueKeysWithValues: detected.map { ($0.provider, $0) })
            _ = self.installPreparedStart(
                apiKey: key,
                brainRoute: brainRoute,
                detectedCLIs: detectedCLIs,
                wasRunning: wasRunning,
                reportContext: reportContext)
        }
        return true
    }

    /// Install a fully prepared route on the main actor. The primary preflight still happens before
    /// tearing down a running pipeline, while unavailable fallback CLIs remain ordered skip targets.
    private func installPreparedStart(
        apiKey key: String,
        brainRoute: BrainRoute,
        detectedCLIs initialDetectedCLIs: [BrainProvider: DetectedAgentCLI],
        wasRunning: Bool,
        reportContext: UserFacingError.PresentationContext
    ) -> Bool {
        let brainProvider = brainRoute.primary.provider
        var detectedCLIs = initialDetectedCLIs
        let preflight = preflightBrainProvider(
            brainProvider, detectedCLI: detectedCLIs[brainProvider],
                                               context: reportContext,
                                               recordSettingsFailure: wasRunning)
        guard preflight.isReady else {
            refreshConnectionUI()
            return false
        }
        if let primaryCLI = preflight.cli {
            detectedCLIs[brainProvider] = primaryCLI
        }
        stop() // tear down any existing pipeline so we start cleanly
        reportedTranscriptionFailure = false
        // A fresh transcript for the fresh pipeline. Reusing the old one would re-send a dead run's
        // lines as "new since last turn" — their [mm:ss] stamps minted against the previous
        // transcriber's clock — and anchor silence math to old speech.
        transcript = RollingTranscript()
        beginNewSession()  // rotate to a fresh session dir + activity/debug log
        overlayBox.clear() // …and a fresh response history for the new conversation

        // Each target's coach and summarizer share the session traffic log. Every fresh attempt is a
        // distinct audit-visible request; no transport wrapper replays a failed request.
        let sessionDirectory = currentSessionDir!
        let configuredRoute = makeConfiguredRoute(
            brainRoute,
            detectedCLIs: detectedCLIs,
            apiKey: key,
            effort: brainPreferences.effort,
            sessionDirectory: sessionDirectory)
        // Fan each spoken tip out to both the Overlay Caption and the persistent Overlay Box.
        let overlaySink = BroadcastOverlay([overlayCaption, overlayBox])
        let driver = CoachDriver(
            config: config,
            transcript: transcript,
            route: configuredRoute,
            screen: WindowScopedScreenCapture(preferences: screenPreferences),
            overlay: overlaySink,
            clock: clock)

        // CoachDriver is @unchecked Sendable; capture it (not @MainActor self) in the callbacks.
        // Route turns through TurnTaskBox so Stop can cancel an in-flight one. Concurrent triggers are
        // coalesced inside CoachDriver (the running turn batches them in), so we don't cancel here.
        let turns = TurnTaskBox()
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
        transcriber.onSpeechActivityChanged = {
            driver.updateSpeechActivity($0, for: .me)
        }

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
        themTranscriber.onSpeechActivityChanged = {
            driver.updateSpeechActivity($0, for: .them)
        }
        // Bind terminal callbacks to the transcriber that emitted them. A callback already queued
        // across Stop → Start must not report against or tear down the replacement session.
        transcriber.onTerminalFailure = { [weak self, weak transcriber] reason in
            guard let transcriber else { return }
            Task { @MainActor [weak self] in
                guard let self, self.transcriber === transcriber else { return }
                self.reportTranscriptionFailure(reason)
            }
        }
        themTranscriber.onTerminalFailure = { [weak self, weak themTranscriber] reason in
            guard let themTranscriber else { return }
            Task { @MainActor [weak self] in
                guard let self, self.themTranscriber === themTranscriber else { return }
                if reason != .connectionLost {
                    self.reportTranscriptionFailure(reason)
                    return
                }
                // A system-audio connection loss degrades gracefully: stop that transcriber while
                // microphone coaching continues. The shared capture simply drops tap audio.
                themTranscriber.stop()
                self.themTranscriber = nil
                // The transcriber's asynchronous `.stopped` callback is identity-guarded and will
                // be ignored after nil-ing it, so commit the degraded state explicitly here.
                self.systemConnectionState = .failed
                self.refreshConnectionUI()
                ActivityLog.shared.record(.systemAudioStopped)
                self.errorReporter.reportImmediately(.systemAudioStopped, context: .runtime)
            }
        }

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
        // Like the transcriber callbacks above, bind the failure to the capture that emitted it. A
        // final retry from an old capture may arrive after Stop → Start; it must not tear down the
        // replacement session through ErrorReporter's global `onFatal`.
        capture.onUnavailable = { [weak self, weak capture] reason in
            guard let capture else { return }
            Task { @MainActor [weak self] in
                guard let self, self.aggregateCapture === capture else { return }
                ActivityLog.shared.record(.audioCaptureStopped)
                self.errorReporter.reportImmediately(
                    .captureStopped(reason: reason), context: .runtime)
            }
        }
        self.transcriber = transcriber
        self.themTranscriber = themTranscriber
        self.aggregateCapture = capture
        self.turns = turns
        self.coachDriver = driver
        activeBrainTarget = brainRoute.primary
        pendingBrainChangeFrom = nil
        brainSection.setActiveTarget(brainRoute.primary)
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
            if reportContext == .runtime {
                ActivityLog.shared.record(.audioCaptureStopped)
            }
            errorReporter.reportImmediately(
                .captureFailed(reason: reason), context: reportContext)
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
        pendingStartRevision &+= 1
        pendingStartTask?.cancel()
        pendingStartTask = nil
        let wasRunning = transcriber != nil || themTranscriber != nil
        requestManualHint = nil              // hotkey beeps again once there's no live session
        let cancelled = turns?.cancelAll() ?? []; turns = nil   // cancel any in-flight coaching turn
        coachDriver = nil
        activeBrainTarget = nil
        pendingBrainChangeFrom = nil
        brainSection?.setActiveTarget(nil)
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
        // Activity writes are asynchronous during live capture. Persist every fixed failure outcome
        // before this session can become evaluable, or an immediate Evaluate could miss why it ended.
        ActivityLog.shared.flush()
        // The just-stopped session becomes evaluable only once any cancelled turn has actually
        // finished unwinding — its brain request records a final traffic line on the way out, and an
        // Evaluate click before that line lands would audit an incomplete brain-traffic.jsonl.
        if !cancelled.isEmpty {
            drainingStops += 1
            Task { @MainActor [weak self] in
                for task in cancelled { await task.value }
                guard let self else { return }
                ActivityLog.shared.flush()
                self.drainingStops -= 1
                self.activityViewer?.coachingStateDidChange()
            }
        }
        activityViewer?.coachingStateDidChange()
    }

    /// Deduplicate the two sockets sharing one OpenAI key: either can discover a permanent account or
    /// configuration failure first, but Activity should show one reason and teardown should run once.
    private func reportTranscriptionFailure(_ reason: TranscriptionFailureReason) {
        guard !reportedTranscriptionFailure, transcriber != nil || themTranscriber != nil else { return }
        reportedTranscriptionFailure = true
        ActivityLog.shared.record(.transcriptionStopped(reason: reason))
        // This method already runs on the main actor after checking the emitting transcriber's
        // identity. Deliver synchronously so Stop → Start cannot slip between that check and the
        // terminal lifecycle consequence and let a stale failure stop the replacement session.
        errorReporter.reportImmediately(
            .transcriptionStopped(reason: reason), context: .runtime)
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

    /// The agentic evaluator must inspect the live source checkout, not a baked description. Prefer
    /// an explicit launch argument, then the workspace-local `.jarvis/` parent used by build-app.sh,
    /// then the directory containing a locally built Jarvis.app. A redistributed bundle without a
    /// checkout simply reports evaluation unavailable instead of running a weaker evaluator.
    private func evaluationRepositoryDirectory() -> URL? {
        let args = CommandLine.arguments
        var candidates: [URL] = []
        if let i = args.firstIndex(of: "--repo-dir"), i + 1 < args.count {
            candidates.append(URL(fileURLWithPath: args[i + 1]))
        }
        let logs = logDirectory().standardizedFileURL
        if logs.lastPathComponent == ".jarvis" {
            candidates.append(logs.deletingLastPathComponent())
        }
        candidates.append(Bundle.main.bundleURL.deletingLastPathComponent())

        return candidates.first { candidate in
            let root = candidate.standardizedFileURL
            return FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Package.swift").path)
                && FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("Sources/JarvisCore").path)
        }?.standardizedFileURL
    }
}
