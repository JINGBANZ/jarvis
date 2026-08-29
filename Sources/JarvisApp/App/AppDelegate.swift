import AppKit
import JarvisBrainProviders
import JarvisCore
import JarvisEvaluation
import JarvisOverlay

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, BrainCompositionHost {
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
    /// Sparkle, for the menu bar's explicit update check. Nil in a development bundle.
    private var updates: UpdateController?
    private var settingsWindow: SettingsWindow!
    private var brainSection: BrainSection!
    private let appearance = OverlayAppearance()
    /// Provider preflight, brain-client construction, route construction, and live reapply.
    /// See `BrainComposition` for the boundary; this delegate is its host.
    private var brain: BrainComposition!
    private let transcriptionPreferences = TranscriptionPreferences()
    private let screenPreferences = ScreenCapturePreferences()
    private let prepMaterialPreferences = PrepMaterialPreferences()
    /// Monotonic revision stamped on each control-plane snapshot. Bumped at Start and whenever an
    /// explicit Settings edit installs a fresh plan; never by runtime health.
    private var planRevision: UInt = 0
    private var activityViewer: ActivityViewer!    // embedded as the Settings Activity tab
    /// Two provider sessions feeding one shared transcript: mic → `.me`, system audio → `.them`.
    private var transcriber: (any TranscriptionSession)?       // "me" (mic)
    private var themTranscriber: (any TranscriptionSession)?   // "them" (system audio)
    /// Overall readiness is composed in Core. The App owns only the active generation token and the
    /// OS/provider observations it feeds into that reducer.
    private let readiness = JarvisReadiness()
    private var readinessSession: JarvisReadiness.Session?
    private var micConnectionState: TranscriptionConnectionState = .stopped
    private var systemConnectionState: TranscriptionConnectionState = .stopped
    private var reportedTranscriptionFailure = false
    /// Proves audio frames are actually flowing before Jarvis claims readiness, and turns a sustained
    /// capture stall into a typed consequence. Recreated per session; observations and its poll clock
    /// are session-relative to `captureReadinessStart`. See `CaptureReadinessMonitor`.
    private var captureReadiness: CaptureReadinessMonitor?
    private var captureReadinessStart: TimeInterval = 0
    private var captureReadinessTimer: Timer?
    /// Resource allocation begins before audio capture can prove startup succeeded. Keep that
    /// provisional state separate so tearing it down cannot look like the end of a live session.
    private var sessionIsLive = false
    /// One-clock capture: a single private aggregate device (built-in mic + system-output tap on one
    /// drift-compensated clock) feeds both transcription endpoints, running AEC3 inside its IOProc so the
    /// other side's speaker bleed is cancelled from the mic. Replaces the separate AVAudioEngine mic +
    /// ScreenCaptureKit capture.
    private var aggregateCapture: AggregateEchoCapture?
    /// In-flight coaching turns, so Stop can cancel one mid-brain-call (otherwise it could speak
    /// after the user pressed Stop).
    private var turns: TurnTaskBox?
    /// The running session's event loop. Stored so Brain Settings can replace only its model clients
    /// without restarting transcription or discarding the session's transcript/history.
    private var coachDriver: CoachDriver?
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
    /// Everything this session leaves on disk: the owner-only directory, the evidence handle in it,
    /// retention pruning, and the close bookkeeping. See `SessionArtifacts` for the boundary.
    private let artifacts = SessionArtifacts()
    /// Only cancelled coaching work extends the global ghost lifecycle. Audit persistence is scoped
    /// to its own session: Activity can use closed history while an unrelated audit drains.
    private var pendingTurnDrainIDs: Set<UUID> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        brain = BrainComposition(secrets: secrets, coachTools: coachTools, host: self)
        NSApp.setActivationPolicy(.accessory) // ghost-mode-allowed: launch configuration
        MainMenu.install() // an Edit menu so ⌘X/⌘C/⌘V/⌘A work in the Settings text fields
        networkDiagnostics.start()

        // The activity viewer lives for the whole app run, but a *session* is one coaching run: each
        // Start opens a fresh session dir + logs (see `beginNewSession`). No session exists until the
        // first Start, so the viewer starts with no current session to browse.
        activityViewer = ActivityViewer(log: .shared,
                                        store: SessionStore(base: artifacts.logDirectory(), current: nil))
        // Evaluation/report opening is explicit Activity UI and remains unavailable while coaching
        // runs—or while a cancelled turn is still draining—so it cannot reveal Jarvis during the
        // ghost lifecycle.
        activityViewer.isCoachingRunning = { [weak self] in
            guard let self else { return false }
            return self.transcriber != nil || !self.pendingTurnDrainIDs.isEmpty
        }
        activityViewer.isSessionAuditClosed = { [weak self] directory in
            self?.artifacts.isAuditClosed(for: directory) ?? true
        }
        activityViewer.protectedSessionDirectories = { [weak self] in
            self?.artifacts.protectedAuditDirectories() ?? []
        }
        // Session artifacts own the directory rotation; the viewer is told about it rather than
        // reached for from inside that owner.
        artifacts.onSessionDidChange = { [weak self] base, current in
            self?.activityViewer.sessionDidChange(base: base, current: current)
        }
        artifacts.onHistoryDidChange = { [weak self] in
            self?.activityViewer?.historyDidChange()
        }
        // The button launches the same sole agentic evaluator as scripts/eval-session.sh. Resolve the
        // checkout at click time and read the current provider preference then, so Settings changes
        // and a moved local app bundle are both reflected without rebuilding Activity.
        activityViewer.makeEvaluator = { [weak self] in
            guard let self, let repository = self.artifacts.evaluationRepositoryDirectory() else { return nil }
            return AgenticEvaluator(repositoryDirectory: repository,
                                    preferredProvider: self.brain.preferences.provider)
        }

        // Ask for Microphone + Screen Recording up front, not lazily mid-session.
        Permissions.primeAll()

        overlayCaption = OverlayCaptionPanel()
        overlayCaption.setFontSize(appearance.captionFontSize)
        overlayCaption.setBackgroundOpacity(appearance.captionBackgroundOpacity)
        overlayCaption.setEnabled(appearance.captionEnabled)   // off by default

        overlayBox = OverlayBoxPanel(contentSize: NSSize(
            width: appearance.boxWidth, height: appearance.boxHeight))
        overlayBox.setFontSize(appearance.boxFontSize)
        overlayBox.setOpacity(appearance.boxOpacity)
        // The panel reports a finished resize drag; persistence stays here, beside the other
        // overlay settings, so the panel keeps knowing nothing about UserDefaults.
        overlayBox.onSizeChanged = { [appearance] width, height in
            appearance.boxWidth = width
            appearance.boxHeight = height
        }
        overlayBox.setEnabled(appearance.boxEnabled)   // on by default — shows the history box at launch

        // No updater in a development bundle (no feed URL), so the menu omits the item entirely.
        updates = UpdateController()
        menuBar = MenuBarController(
            updateAvailability: updates.map { updater in { updater.canCheckForUpdates } },
            onCheckForUpdates: updates.map { updater in { updater.checkForUpdates() } })
        renderReadinessStatus(readiness.status)

        // Unified Settings window: Brain owns behavior; Connections owns shared authentication.
        // A pasted key is stored but does not auto-start. While running, it updates future Realtime
        // connections and transactionally replaces only an OpenAI brain—never the capture/transcript
        // pipeline.
        brainSection = BrainSection(
            preferences: brain.preferences,
            detector: brain.detector,
            onPreferencesChanged: { [weak self] change, clis in
                self?.brain.applyBrainPreferencesToRunningSession(
                    detectedCLIs: clis,
                    update: change == .topology ? .topologyEdit : .effortEdit)
            },
            transcriptionPreferences: transcriptionPreferences)
        let connectionsSection = ConnectionsSection(
            detector: brain.detector,
            keyStore: secretFile,
            onKeySaved: { [weak self] key in
                self?.applySavedAPIKeyToRunningSession(key)
            })
        let sections: [SettingsSection] = [
            brainSection,
            connectionsSection,
            OverlaySection(appearance: appearance, caption: overlayCaption, box: overlayBox),
            DisplaySection(preferences: screenPreferences) { [weak self] in
                self?.reapplySessionPlan()
            },
            PrepMaterialSection(preferences: prepMaterialPreferences),
            ActivitySection(viewer: activityViewer),
        ]
        settingsWindow = SettingsWindow(sections: sections)
        menuBar.onOpenSettings = { [weak self] in self?.settingsWindow.show() }

        // The menu drives the pipeline lifecycle. Jarvis does NOT auto-start; the user presses Start.
        menuBar.onStart = { [weak self] in self?.start() ?? false }
        menuBar.onStop = { [weak self] in self?.stop(reason: .stoppedByUser) }

        // A fatal error tears the session down and corrects the menu — one place owns that.
        errorReporter.onFatal = { [weak self] reason in
            self?.stop(reason: reason)
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

        if transcriptionPreferences.provider.requiresOpenAIAPIKey(
            for: brain.preferences.route
        ), secrets.apiKey()?.isEmpty != false {
            jlog("Jarvis: no OpenAI API key yet — paste it in Settings, then press Start.")
        } else {
            jlog("Jarvis: ready — press Start in the menu bar to begin coaching.")
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        activityViewer?.cancelEvaluation()
        stop(reason: .applicationQuit)
        return .terminateNow
    }








    /// Keep a healthy live conversation intact when the credential file changes. Existing Realtime
    /// sockets are already authenticated; retain them and use the new key only if either socket later
    /// reconnects. The transcription half is session runtime and stays here; the brain half is
    /// composition's, and it installs fresh OpenAI target clients between coaching attempts without
    /// probing or replacing CLI clients, changing route policy, or restarting transcription.
    private func applySavedAPIKeyToRunningSession(_ key: String) {
        guard let transcriber else { return }
        (transcriber as? RealtimeTranscriber)?.updateAPIKey(key)
        (themTranscriber as? RealtimeTranscriber)?.updateAPIKey(key)
        brain.applySavedAPIKey(key)
    }

    /// Validate a Start immediately, then prepare any local-CLI targets and on-device speech assets.
    /// Returns `true` once startup is accepted; the menu remains in Starting until preparation and
    /// both transcription endpoints finish. Stop, a newer Start, or a relevant preference/credential
    /// edit makes the prepared result stale before it can install a pipeline.
    @discardableResult
    private func start() -> Bool {
        let wasRunning = transcriber != nil || themTranscriber != nil
        let reportContext: UserFacingError.PresentationContext =
            wasRunning ? .runtime : .startup
        let transcriptionConfiguration = transcriptionPreferences.configuration
        let transcriptionProvider = transcriptionConfiguration.provider
        let brainRoute = brain.preferences.route
        let key = secrets.apiKey() ?? ""
        let requiresOpenAIKey = transcriptionProvider.requiresOpenAIAPIKey(for: brainRoute)
        let preparesAppleSpeech = transcriptionProvider == .appleSpeech
        let readinessConfiguration = JarvisReadiness.Configuration(
            requiredPermissions: [.microphone],
            requiredCredentials: requiresOpenAIKey ? [.openAIAPIKey] : [],
            requiresTranscriptionPreparation: preparesAppleSpeech)
        let readinessStart = readiness.begin(configuration: readinessConfiguration)
        let readinessSession = readinessStart.session
        self.readinessSession = readinessSession
        applyReadinessEffects(readinessStart.effects)

        let grantedPermissions = Permissions.grantedReadinessPermissions()
        observeReadiness(.permissions(granted: grantedPermissions), for: readinessSession)
        let missingPermissions = readinessConfiguration.requiredPermissions
            .subtracting(grantedPermissions)
        guard missingPermissions.isEmpty else {
            jlog("Jarvis: can't start — required permissions are missing: "
                 + missingPermissions.map(\.rawValue).sorted().joined(separator: ", "))
            if wasRunning {
                artifacts.sessionAudit?.record(.settingsChangeNotApplied)
            }
            errorReporter.reportImmediately(
                .permissionsMissing(missingPermissions),
                context: reportContext)
            return false
        }

        let availableCredentials: Set<JarvisReadiness.Credential> = key.isEmpty
            ? [] : [.openAIAPIKey]
        observeReadiness(.credentials(available: availableCredentials), for: readinessSession)
        guard !requiresOpenAIKey || !key.isEmpty else {
            jlog("Jarvis: can't start — no API key.")
            if wasRunning {
                artifacts.sessionAudit?.record(.settingsChangeNotApplied)
            }
            errorReporter.reportImmediately(.noAPIKey, context: reportContext)
            return false
        }

        pendingStartRevision &+= 1
        let revision = pendingStartRevision
        pendingStartTask?.cancel()
        pendingStartTask = nil
        let cliProviders = brainRoute.targets.map(\.provider).filter(\.usesLocalCLI)
        guard preparesAppleSpeech || !cliProviders.isEmpty else {
            return installPreparedStart(
                apiKey: key,
                brainRoute: brainRoute,
                transcriptionConfiguration: transcriptionConfiguration,
                appleSpeechLocale: nil,
                detectedCLIs: [:],
                wasRunning: wasRunning,
                reportContext: reportContext,
                readinessSession: readinessSession)
        }

        let detector = AgentCLIDetector()
        pendingStartTask = Task { [weak self] in
            guard let self else { return }
            var appleSpeechLocale: Locale?
            if preparesAppleSpeech {
                guard #available(macOS 26.0, *) else {
                    self.rejectPreparedStart(
                        .appleSpeechUnavailable,
                        diagnostic: "Apple Speech requires macOS 26 or later.",
                        revision: revision,
                        wasRunning: wasRunning,
                        context: reportContext,
                        readinessSession: readinessSession,
                        blocker: .unavailable)
                    return
                }
                do {
                    appleSpeechLocale = try await AppleSpeechModelPreparation.prepare(
                        localeIdentifier:
                            transcriptionConfiguration.appleSpeechLocaleIdentifier)
                } catch {
                    guard !Task.isCancelled, self.pendingStartRevision == revision else {
                        return
                    }
                    let userError: UserFacingError
                    if error is AppleSpeechModelPreparation.Failure {
                        userError = .appleSpeechUnavailable
                    } else {
                        userError = .appleSpeechPreparationFailed
                    }
                    self.rejectPreparedStart(
                        userError,
                        diagnostic: "Apple Speech preparation failed: \(error)",
                        revision: revision,
                        wasRunning: wasRunning,
                        context: reportContext,
                        readinessSession: readinessSession,
                        blocker: error is AppleSpeechModelPreparation.Failure
                            ? .unavailable : .preparationFailed)
                    return
                }
                guard !Task.isCancelled,
                      self.pendingStartRevision == revision,
                      self.readinessSession == readinessSession else { return }
                self.observeReadiness(
                    .transcriptionPreparation(.ready), for: readinessSession)
            }
            let detected = await detector.detectAllAsync(cliProviders)
            guard !Task.isCancelled,
                  self.pendingStartRevision == revision,
                  self.readinessSession == readinessSession else {
                return
            }
            let credentialIsCurrent = !requiresOpenAIKey
                || (self.secrets.apiKey() ?? "") == key
            guard credentialIsCurrent,
                  self.transcriptionPreferences.configuration == transcriptionConfiguration,
                  self.brain.preferences.route == brainRoute else {
                self.pendingStartTask = nil
                self.cancelReadinessAttempt(readinessSession)
                return
            }
            self.pendingStartTask = nil
            let detectedCLIs = Dictionary(
                uniqueKeysWithValues: detected.map { ($0.provider, $0) })
            _ = self.installPreparedStart(
                apiKey: key,
                brainRoute: brainRoute,
                transcriptionConfiguration: transcriptionConfiguration,
                appleSpeechLocale: appleSpeechLocale,
                detectedCLIs: detectedCLIs,
                wasRunning: wasRunning,
                reportContext: reportContext,
                readinessSession: readinessSession)
        }
        return true
    }

    private func rejectPreparedStart(
        _ error: UserFacingError,
        diagnostic: String,
        revision: UInt,
        wasRunning: Bool,
        context: UserFacingError.PresentationContext,
        readinessSession: JarvisReadiness.Session,
        blocker: JarvisReadiness.TranscriptionBlocker
    ) {
        guard pendingStartRevision == revision,
              self.readinessSession == readinessSession else { return }
        pendingStartTask = nil
        observeReadiness(
            .transcriptionPreparation(.blocked(blocker)), for: readinessSession)
        jlog("Jarvis: can't start — \(diagnostic)")
        if wasRunning {
            artifacts.sessionAudit?.record(.settingsChangeNotApplied)
        }
        errorReporter.reportImmediately(error, context: context)
    }

    /// Install a fully prepared route on the main actor. The primary preflight still happens before
    /// tearing down a running pipeline, while unavailable fallback CLIs remain ordered skip targets.
    private func installPreparedStart(
        apiKey key: String,
        brainRoute: BrainRoute,
        transcriptionConfiguration: TranscriptionConfiguration,
        appleSpeechLocale: Locale?,
        detectedCLIs initialDetectedCLIs: [BrainProvider: DetectedAgentCLI],
        wasRunning: Bool,
        reportContext: UserFacingError.PresentationContext,
        readinessSession: JarvisReadiness.Session
    ) -> Bool {
        guard self.readinessSession == readinessSession else { return false }
        let brainProvider = brainRoute.primary.provider
        var detectedCLIs = initialDetectedCLIs
        let preflight = brain.preflightBrainProvider(
            brainProvider, detectedCLI: detectedCLIs[brainProvider],
                                               context: reportContext,
                                               recordSettingsFailure: wasRunning)
        guard preflight.isReady else {
            observeReadiness(
                .brainPreparation(.blocked(.providerUnavailable)),
                for: readinessSession)
            return false
        }
        if let primaryCLI = preflight.cli {
            detectedCLIs[brainProvider] = primaryCLI
        }
        stop(reason: .replacedByNewSession, preserving: readinessSession)
        reportedTranscriptionFailure = false
        // A fresh transcript for the fresh pipeline. Reusing the old one would re-send a dead run's
        // lines as "new since last turn" — their [mm:ss] stamps minted against the previous
        // transcriber's clock — and anchor silence math to old speech.
        transcript = RollingTranscript()
        artifacts.beginNewSession()  // rotate to a fresh session dir + activity/debug log
        overlayBox.clear() // …and a fresh response history for the new conversation
        switch transcriptionConfiguration.provider {
        case .openAI:
            jlog(
                "Jarvis transcription: provider=OpenAI "
                    + "model=\(transcriptionConfiguration.openAIModel.rawValue) "
                    + "expected-languages="
                    + (transcriptionConfiguration.openAIExpectedLanguages.isEmpty
                        ? "automatic"
                        : transcriptionConfiguration.openAIExpectedLanguages
                            .map(\.rawValue).joined(separator: ",")))
        case .appleSpeech:
            jlog(
                "Jarvis transcription: provider=Apple Speech "
                    + "locale=\(appleSpeechLocale?.identifier ?? "unprepared")")
        }

        // Each target's coach and summarizer share the session traffic log. Every fresh attempt is a
        // distinct audit-visible request; no transport wrapper replays a failed request.
        let sessionDirectory = artifacts.currentSessionDir!
        let configuredRoute = brain.makeConfiguredRoute(
            brainRoute,
            detectedCLIs: detectedCLIs,
            apiKey: key,
            effort: brain.preferences.effort,
            sessionDirectory: sessionDirectory)
        observeReadiness(.brainPreparation(.ready), for: readinessSession)
        // One time origin makes mic/system timestamps directly comparable. Each provider may finish
        // independently, but neither gets its own definition of "seconds since session start."
        let conversationStart = clock.now()
        // Fan each spoken tip out to both the Overlay Caption and the persistent Overlay Box.
        let overlaySink = BroadcastOverlay([overlayCaption, overlayBox])
        let driver = CoachDriver(
            config: config,
            transcript: transcript,
            route: configuredRoute,
            screen: WindowScopedScreenCapture(captureDirectory: sessionDirectory),
            overlay: overlaySink,
            clock: clock,
            sessionStart: conversationStart,
            coachingAttempts: artifacts.sessionAudit,
            plan: freshSessionPlan(),
            activity: artifacts.sessionAudit)

        // Building the index reads files and can shell out to `textutil`, so it runs off the Start
        // path entirely rather than delaying it — a trigger that fires before this lands just
        // doesn't have search_prep_notes available for that one attempt.
        let prepMaterialSources = prepMaterialPreferences.sources
        Task.detached(priority: .utility) {
            let index = await PrepMaterialIndexBuilder.build(from: prepMaterialSources)
            driver.installPrepMaterial(index)
        }

        // CoachDriver is @unchecked Sendable; capture it (not @MainActor self) in the callbacks.
        // Route turns through TurnTaskBox so Stop can cancel an in-flight one. Concurrent triggers are
        // coalesced inside CoachDriver (the running turn batches them in), so we don't cancel here.
        let turns = TurnTaskBox()
        // "Me" side: the mic. Drives turn-end and the backing-off silence check ("are you stuck?").
        let transcriber = TranscriptionSessionFactory.make(
            configuration: transcriptionConfiguration,
            apiKey: key,
            appleSpeechLocale: appleSpeechLocale,
            speaker: .me,
            transcript: transcript,
            clock: clock,
            sessionStart: conversationStart,
            config: config,
            networkStatus: { [networkDiagnostics] in
                networkDiagnostics.currentSummary
            },
            activity: artifacts.sessionAudit)
        transcriber.onTurnEnd = { boundary in
            turns.run {
                await driver.handleTrigger(.turnEnd, transcriptBoundary: boundary)
            }
        }
        transcriber.onSilence = { secs in turns.run { await driver.handleTrigger(.silence(secondsQuiet: secs)) } }
        transcriber.onTranscriptionWorkChanged = {
            driver.updateTranscriptionWork($0, for: .me)
        }

        // "Them" side: system audio (remote participants). Drives turn-end so Jarvis can react when the
        // other side finishes (e.g. asks you something), but NOT the silence check — the "are you
        // stuck?" prompt is about the *user*, so only the mic owns that timer.
        let themTranscriber = TranscriptionSessionFactory.make(
            configuration: transcriptionConfiguration,
            apiKey: key,
            appleSpeechLocale: appleSpeechLocale,
            speaker: .them,
            transcript: transcript,
            clock: clock,
            sessionStart: conversationStart,
            config: config,
            networkStatus: { [networkDiagnostics] in
                networkDiagnostics.currentSummary
            },
            activity: artifacts.sessionAudit)
        themTranscriber.onTurnEnd = { boundary in
            turns.run {
                await driver.handleTrigger(.turnEnd, transcriptBoundary: boundary)
            }
        }
        themTranscriber.onTranscriptionWorkChanged = {
            driver.updateTranscriptionWork($0, for: .them)
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
                if transcriptionConfiguration.provider == .openAI,
                   reason != .connectionLost {
                    self.reportTranscriptionFailure(reason)
                    return
                }
                // A system-audio transport loss or local analyzer failure degrades gracefully: stop
                // that endpoint while microphone coaching continues. The shared capture drops tap audio.
                themTranscriber.stop()
                self.themTranscriber = nil
                // The transcriber's asynchronous `.stopped` callback is identity-guarded and will
                // be ignored after nil-ing it, so commit the degraded state explicitly here.
                self.systemConnectionState = .failed
                // Stop expecting system frames so a capture first-frame/stall timeout can't also fire.
                self.captureReadiness?.systemBecameUnavailable()
                self.observeEndpointAndCaptureReadiness(
                    stream: .system, state: .failed, for: readinessSession)
                self.artifacts.sessionAudit?.record(.systemAudioStopped)
                self.errorReporter.reportImmediately(.systemAudioStopped, context: .runtime)
            }
        }

        // One-clock capture + echo cancellation: a single aggregate device (mic + system tap) feeds
        // the cleaned mic to the "me" socket and the sample-preserving system timeline to the "them"
        // socket, with AEC3 run inside its IOProc. If the device can't be built, the whole capture is
        // gone, so treat it as a full (mic-side) terminal failure.
        let localTurnDetectionSilenceDuration: TimeInterval? =
            transcriptionConfiguration.turnDetectionStrategy == .clientCommit
            ? TimeInterval(config.vadSilenceDurationMs) / 1_000
            : nil
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
            },
            localTurnDetectionSilenceDuration: localTurnDetectionSilenceDuration,
            onMicSpeechEvent: { [weak transcriber] event, sequence in
                transcriber?.recordLocalSpeechEvent(
                    event, throughSequenceNumber: sequence)
            },
            onSystemSpeechEvent: { [weak themTranscriber] event, sequence in
                themTranscriber?.recordLocalSpeechEvent(
                    event, throughSequenceNumber: sequence)
            })
        // Like the transcriber callbacks above, bind the failure to the capture that emitted it. A
        // final retry from an old capture may arrive after Stop → Start; it must not tear down the
        // replacement session through ErrorReporter's global `onFatal`.
        capture.onUnavailable = { [weak self, weak capture] reason in
            guard let capture else { return }
            Task { @MainActor [weak self] in
                guard let self, self.aggregateCapture === capture else { return }
                self.observeReadiness(.capture(.stopped), for: readinessSession)
                self.errorReporter.reportImmediately(
                    .captureStopped(reason: reason), context: .runtime)
            }
        }
        capture.onRecoveryStateChange = { [weak self, weak capture] inProgress in
            guard let capture else { return }
            Task { @MainActor [weak self] in
                guard let self, self.aggregateCapture === capture,
                      let monitor = self.captureReadiness else { return }
                monitor.setCaptureRecoveryInProgress(
                    inProgress, at: self.clock.now() - self.captureReadinessStart)
                self.observeReadiness([
                    .captureRecovery(inProgress: inProgress),
                    .capture(monitor.readiness),
                ], for: readinessSession)
            }
        }
        self.transcriber = transcriber
        self.themTranscriber = themTranscriber
        self.aggregateCapture = capture
        self.turns = turns
        self.coachDriver = driver
        brain.sessionWillStart(on: brainRoute.primary)
        brainSection.setActiveTarget(brainRoute.primary)
        micConnectionState = .connecting
        systemConnectionState = .connecting
        observeReadiness([
            .transcriptionEndpoint(stream: .microphone, state: .connecting),
            .transcriptionEndpoint(stream: .system, state: .connecting),
        ], for: readinessSession)
        transcriber.onCaptureHeartbeat = { [weak self, weak transcriber] signal in
            guard let transcriber else { return }
            Task { @MainActor [weak self] in
                guard let self, self.transcriber === transcriber else { return }
                self.handleCaptureHeartbeat(
                    signal, for: .microphone, readinessSession: readinessSession)
            }
        }
        themTranscriber.onCaptureHeartbeat = { [weak self, weak themTranscriber] signal in
            guard let themTranscriber else { return }
            Task { @MainActor [weak self] in
                guard let self, self.themTranscriber === themTranscriber else { return }
                self.handleCaptureHeartbeat(
                    signal, for: .system, readinessSession: readinessSession)
            }
        }
        transcriber.onConnectionStateChange = { [weak self, weak transcriber] state in
            guard let transcriber else { return }
            Task { @MainActor [weak self] in
                guard let self, self.transcriber === transcriber else { return }
                self.handleTranscriptionConnectionState(
                    state, for: .microphone, readinessSession: readinessSession)
            }
        }
        themTranscriber.onConnectionStateChange = { [weak self, weak themTranscriber] state in
            guard let themTranscriber else { return }
            Task { @MainActor [weak self] in
                guard let self, self.themTranscriber === themTranscriber else { return }
                self.handleTranscriptionConnectionState(
                    state, for: .system, readinessSession: readinessSession)
            }
        }
        // Arm the hint hotkey for this session: capture the screen and force a one-trip hint, routed
        // through the same turn box as audio triggers (so Stop cancels it and rapid presses coalesce).
        self.requestManualHint = { turns.run { await driver.handleTrigger(.manualHint) } }
        transcriber.connect()
        themTranscriber.connect()
        if let reason = capture.start() {
            observeReadiness(.capture(.stopped), for: readinessSession)
            errorReporter.reportImmediately(
                .captureFailed(reason: reason), context: reportContext)
            return false
        }
        // Capture setup is synchronous and can legitimately take longer than the first-frame
        // deadline. Arm that deadline only after AudioDeviceStart succeeds; callbacks were installed
        // above, so any frame already queued on the main actor is still observed by this monitor.
        startCaptureReadiness(readinessSession: readinessSession)
        sessionIsLive = true
        jlog("Jarvis: coaching starting — verifying transcription endpoints.")
        jlog("Jarvis network path at start: \(networkDiagnostics.currentSummary)")
        activityViewer.coachingStateDidChange()   // the live session is no longer evaluable
        return true
    }

    /// Stop and tear down the capture (one aggregate device) and BOTH transcription endpoints
    /// (mic/"me" and system-audio/"them"). Safe to call when already stopped. The capture and both
    /// transcribers must go: otherwise a turn-end trigger from a still-live socket could drive a
    /// coaching turn on a torn-down driver — the exact "speak after Stop" failure the turns box exists
    /// to prevent — and a subsequent Start would leak the orphaned IOProc/endpoints.
    private func stop(
        reason: SessionEndReason,
        preserving readinessToPreserve: JarvisReadiness.Session? = nil
    ) {
        pendingStartRevision &+= 1
        pendingStartTask?.cancel()
        pendingStartTask = nil
        let hadAllocatedPipeline = transcriber != nil || themTranscriber != nil
        let preservesReplacementReadiness = readinessToPreserve == readinessSession
        let preservesStartupBlock = !hadAllocatedPipeline
            && reason != .applicationQuit
            && readiness.status.isBlocked
        let endedLiveSession = sessionIsLive
        sessionIsLive = false
        requestManualHint = nil              // hotkey beeps again once there's no live session
        // Capture and clear this session handle before a quick Start installs another. The cancelled
        // tasks retain only its observer ports and can finish enqueueing into the old session.
        let (audit, auditDirectory) = artifacts.takeCurrentSession()
        let cancelled = turns?.cancelAll() ?? []; turns = nil   // cancel any in-flight coaching turn
        // History compaction runs off the attempt path, so `turns` does not own it. Cancel it here
        // and drain it below, or a summary keeps a provider process alive and billing after Stop and
        // can still be writing when the audit seals.
        let compaction = coachDriver?.cancelBackgroundWork()
        coachDriver = nil
        brain.sessionDidStop()
        brainSection?.setActiveTarget(nil)
        // Mark both delivery endpoints stopped before draining the IOProc. Aggregate capture hands
        // chunks off asynchronously, so callbacks already queued during teardown must see the
        // transcribers' stopped guards and become no-ops.
        transcriber?.stop()
        themTranscriber?.stop()
        aggregateCapture?.stop(); aggregateCapture = nil   // stop the IOProc, tear down tap+aggregate
        transcriber = nil
        themTranscriber = nil
        stopCaptureReadiness()
        micConnectionState = .stopped
        systemConnectionState = .stopped
        if !preservesReplacementReadiness && !preservesStartupBlock,
           let readinessSession {
            applyReadinessEffects(readiness.stop(session: readinessSession))
            self.readinessSession = nil
        }
        if hadAllocatedPipeline {
            jlog("Jarvis: stopped.")
        }
        if endedLiveSession {
            // `sessionAudit` was already cleared above; record against the handle teardown holds so
            // the marker still reaches this session's evidence rather than the next one's.
            audit?.record(.sessionEnded(reason: reason))
        }
        // Activity is no longer a privileged failure domain: its rows ride the one bounded evidence
        // stack, so Stop drains this session's producers and evidence in the background and a
        // replacement Start stays instant. Quit seals best-effort and returns immediately —
        // evidence never owns app termination, so a last row may be lost and the session is then
        // honestly marked partial.
        if reason == .applicationQuit {
            audit?.abandon()
        } else if audit != nil || !cancelled.isEmpty || compaction != nil {
            let drainID = UUID()
            if !cancelled.isEmpty { pendingTurnDrainIDs.insert(drainID) }
            if let auditDirectory { artifacts.beginClosing(auditDirectory) }
            Task { @MainActor [weak self] in
                for task in cancelled { await task.value }
                await compaction?.value
                self?.pendingTurnDrainIDs.remove(drainID)
                self?.activityViewer?.coachingStateDidChange()
                // Closing the handle is the barrier now: it waits for every accepted row, Activity
                // included, so a just-recorded outcome cannot race the evaluator.
                _ = await audit?.close()
                if let auditDirectory { self?.artifacts.endClosing(auditDirectory) }
                self?.activityViewer?.coachingStateDidChange()
            }
        }
        activityViewer?.coachingStateDidChange()
    }

    // MARK: - BrainCompositionHost

    /// What brain composition may see of the live session, and how it reports back. Read-only
    /// accessors and two presentation forwards — composition never starts, stops, or tears down.
    var liveCoachDriver: CoachDriver? { coachDriver }
    var liveSessionDirectory: URL? { artifacts.currentSessionDir }
    var liveSessionEvidence: FileSessionAudit? { artifacts.sessionAudit }
    var isTranscriptionLive: Bool { transcriber != nil }

    func reportBrainError(
        _ error: UserFacingError, context: UserFacingError.PresentationContext
    ) {
        errorReporter.reportImmediately(error, context: context)
    }

    func brainTargetDidChange(_ target: BrainTarget?) {
        brainSection.setActiveTarget(target)
    }

    /// Deduplicate endpoint failures: either side can fail first, but Activity should show one reason
    /// and teardown should run once.
    private func reportTranscriptionFailure(_ reason: TranscriptionFailureReason) {
        guard !reportedTranscriptionFailure, transcriber != nil || themTranscriber != nil else { return }
        reportedTranscriptionFailure = true
        // This method already runs on the main actor after checking the emitting transcriber's
        // identity. Deliver synchronously so Stop → Start cannot slip between that check and the
        // terminal lifecycle consequence and let a stale failure stop the replacement session.
        errorReporter.reportImmediately(
            .transcriptionStopped(reason: reason), context: .runtime)
    }

    private func observeReadiness(
        _ observation: JarvisReadiness.Observation,
        for session: JarvisReadiness.Session
    ) {
        applyReadinessEffects(readiness.observe(observation, for: session))
    }

    private func observeReadiness(
        _ observations: [JarvisReadiness.Observation],
        for session: JarvisReadiness.Session
    ) {
        applyReadinessEffects(readiness.observe(observations, for: session))
    }

    private func applyReadinessEffects(_ effects: [JarvisReadiness.Effect]) {
        for effect in effects {
            switch effect {
            case .statusChanged(let status):
                renderReadinessStatus(status)
            case .readinessEstablished(.full):
                jlog("Jarvis: coaching ready (mic + system audio).")
            case .readinessEstablished(.microphoneOnly):
                jlog("Jarvis: coaching ready (microphone only).")
            }
        }
    }

    private func renderReadinessStatus(_ status: JarvisReadiness.Status) {
        menuBar?.setStatus(status)
        activityViewer?.readinessDidChange(status)
    }

    private func cancelReadinessAttempt(_ session: JarvisReadiness.Session) {
        guard readinessSession == session else { return }
        applyReadinessEffects(readiness.stop(session: session))
        readinessSession = nil
    }

    /// Keep endpoint connection bookkeeping focused on seeding `CaptureReadinessMonitor`; Core owns
    /// every cross-subsystem status decision and both UI surfaces consume that result.
    private func handleTranscriptionConnectionState(
        _ state: TranscriptionConnectionState,
        for stream: CaptureReadinessMonitor.Stream,
        readinessSession: JarvisReadiness.Session
    ) {
        guard self.readinessSession == readinessSession else { return }
        switch stream {
        case .microphone:
            micConnectionState = state
        case .system:
            systemConnectionState = state
        }
        captureReadiness?.setProviderReady(state == .ready, for: stream)
        observeEndpointAndCaptureReadiness(
            stream: stream, state: state, for: readinessSession)
    }

    private func observeEndpointAndCaptureReadiness(
        stream: CaptureReadinessMonitor.Stream,
        state: TranscriptionConnectionState,
        for session: JarvisReadiness.Session
    ) {
        var observations: [JarvisReadiness.Observation] = [
            .transcriptionEndpoint(stream: stream, state: state),
        ]
        if let captureReadiness {
            observations.append(.capture(captureReadiness.readiness))
        }
        observeReadiness(observations, for: session)
    }

    /// Begin capture-frame readiness tracking for the session being installed. The 1s poll owns the
    /// initial first-frame deadline and the sustained-stall deadline after frame flow begins;
    /// observations arrive through `handleCaptureContinuity`.
    private func startCaptureReadiness(readinessSession: JarvisReadiness.Session) {
        captureReadinessTimer?.invalidate()
        captureReadinessStart = clock.now()
        let monitor = CaptureReadinessMonitor(startedAt: 0)
        monitor.setProviderReady(micConnectionState == .ready, for: .microphone)
        monitor.setProviderReady(systemConnectionState == .ready, for: .system)
        captureReadiness = monitor
        observeReadiness(.capture(monitor.readiness), for: readinessSession)
        captureReadinessTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let monitor = self.captureReadiness,
                      self.readinessSession == readinessSession else { return }
                let effects = monitor.poll(
                    at: self.clock.now() - self.captureReadinessStart)
                self.observeReadiness(.capture(monitor.readiness), for: readinessSession)
                self.applyCaptureReadinessEffects(
                    effects, readinessSession: readinessSession)
            }
        }
    }

    private func stopCaptureReadiness() {
        captureReadinessTimer?.invalidate()
        captureReadinessTimer = nil
        captureReadiness = nil
    }

    /// Fold one capture heartbeat into the focused monitor, then publish only its typed output to
    /// the overall composition reducer. This is the critical branch: everything here is in-memory
    /// policy over the heartbeat value, with no read of the evidence queue or a persisted file.
    private func handleCaptureHeartbeat(
        _ heartbeat: CaptureHeartbeat,
        for stream: CaptureReadinessMonitor.Stream,
        readinessSession: JarvisReadiness.Session
    ) {
        guard self.readinessSession == readinessSession, let captureReadiness else { return }
        let observedAt = clock.now() - captureReadinessStart
        let hadFirstFrame = captureReadiness.hasFirstFrame(stream)
        let effects = captureReadiness.note(
            heartbeat, for: stream, at: observedAt)
        if case .frames(let sampleCount) = heartbeat, sampleCount > 0 {
            if !hadFirstFrame {
                jlog("Jarvis capture readiness [\(stream.rawValue)]: "
                     + "capture=1/\(sampleCount), first=\(String(format: "%.3fs", observedAt))")
            }
        }
        observeReadiness(.capture(captureReadiness.readiness), for: readinessSession)
        applyCaptureReadinessEffects(effects, readinessSession: readinessSession)
    }

    /// Turn readiness consequences into lifecycle effects. A microphone capture failure is terminal; a
    /// system capture failure degrades to microphone-only. Fixed copy goes to Activity; the cause and
    /// counters stay in `jarvis-debug.log`.
    private func applyCaptureReadinessEffects(
        _ effects: [CaptureReadinessMonitor.Effect],
        readinessSession: JarvisReadiness.Session
    ) {
        guard self.readinessSession == readinessSession else { return }
        for effect in effects {
            switch effect {
            case .microphoneCaptureFailed(let cause):
                jlog("Jarvis: microphone capture unhealthy (\(cause.rawValue)) — stopping.")
                errorReporter.reportImmediately(
                    .captureStopped(
                        reason: "Jarvis stopped receiving microphone audio. Check the input device and press Start."),
                    context: .runtime)
            case .degradeToMicrophoneOnly(let cause):
                guard themTranscriber != nil || systemConnectionState != .failed else { break }
                jlog("Jarvis: system audio capture unhealthy (\(cause.rawValue)) — "
                     + "microphone coaching continues.")
                themTranscriber?.stop()
                themTranscriber = nil
                systemConnectionState = .failed
                observeEndpointAndCaptureReadiness(
                    stream: .system, state: .failed, for: readinessSession)
                artifacts.sessionAudit?.record(.systemAudioStopped)
                errorReporter.reportImmediately(.systemAudioStopped, context: .runtime)
            }
        }
    }



    /// Read the persisted control plane once and freeze it as the next revision.
    ///
    /// This is the only place preferences reach a coaching attempt. Everything a turn needs is
    /// resolved here, at Start or at an explicit Settings boundary, so no attempt reads storage
    /// (wiki/lean-coaching-core.md, Phase 4).
    private func freshSessionPlan() -> SessionPlan {
        planRevision &+= 1
        return SessionPlan(revision: planRevision, screen: screenPreferences.selection)
    }

    /// An explicit Settings edit takes effect at the next attempt. A turn already running keeps the
    /// revision it snapshotted, and nothing here rewrites a persisted preference.
    private func reapplySessionPlan() {
        coachDriver?.updatePlan(freshSessionPlan())
    }






}

private extension JarvisReadiness.Status {
    var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }
}
