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
    private let permissionPreferences = PermissionPreferences()
    private var permissionGate: PermissionGate!
    /// Whether the app's own surfaces exist yet. Nothing is built while the permission gate is up.
    private var didStartApp = false
    private var sessionExplanationsEnabled = false
    private let explanationPreferences = ExplanationPreferences()
    private let codePreferences = CodePreferences()
    private var sessionCodeEnabled = false
    private let hotkeyPreferences = CoachingShortcut.allCases.map { HotkeyPreferences(shortcut: $0) }
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
    /// Reads prep-material files and can shell out to `textutil`; cancelled on Stop like compaction
    /// is, so it never outlives the session it was built for.
    private var prepMaterialIndexTask: Task<Void, Never>?
    private var pendingStartRevision: UInt = 0
    /// The global hint hotkey. Lives for the whole app run; its callback beeps when no session runs.
    private var hotkeys: HotkeyController?
    /// Fires an on-demand hint for the running session. Non-nil only while running — set in `start()`,
    /// cleared in `stop()` — so the hotkey beeps when there's no session. Captures the Sendable driver
    /// + turn box (not `@MainActor` self), like the transcriber callbacks do.
    private var requestManualHint: ((CoachingShortcut) -> Void)?
    /// Everything this session leaves on disk: the owner-only directory, the evidence handle in it,
    /// retention pruning, and the close bookkeeping. See `SessionArtifacts` for the boundary.
    private let artifacts = SessionArtifacts()
    /// Only cancelled coaching work extends the global ghost lifecycle. Audit persistence is scoped
    /// to its own session: Activity can use closed history while an unrelated audit drains.
    private var pendingTurnDrainIDs: Set<UUID> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // ghost-mode-allowed: launch configuration
        MainMenu.install() // an Edit menu so ⌘X/⌘C/⌘V/⌘A work in the Settings text fields

        // Nothing else comes up until Jarvis holds every grant: no menu bar, no overlays, no session
        // runtime. A half-permitted Jarvis is not a usable product, and a Start that can only fail is
        // worse than no Start at all.
        permissionGate = PermissionGate(preferences: permissionPreferences)
        permissionGate.onSatisfied = { [weak self] in self?.startApp() }
        // Asynchronous because proving the system-audio grant means running a tap, which must not
        // block the main thread.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if await self.permissionGate.holdsEveryGrant() {
                self.startApp()
            } else {
                self.permissionGate.present()
            }
        }
    }

    /// Builds everything a permitted Jarvis needs. Reached either straight from launch or from the
    /// gate closing, and never twice.
    private func startApp() {
        didStartApp = true
        brain = BrainComposition(secrets: secrets, host: self)
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

        overlayCaption = OverlayCaptionPanel()
        overlayCaption.setFontSize(appearance.captionFontSize)
        overlayCaption.setBackgroundOpacity(appearance.captionBackgroundOpacity)
        overlayCaption.setEnabled(appearance.captionEnabled)   // off by default

        overlayBox = OverlayBoxPanel(contentSize: NSSize(
            width: appearance.boxWidth, height: appearance.boxHeight))
        overlayBox.setFontSize(appearance.boxFontSize)
        overlayBox.setOpacity(appearance.boxOpacity)
        overlayBox.setDiagramsEnabled(appearance.boxDiagramsEnabled)
        // The panel reports a finished resize drag; persistence stays here, beside the other
        // overlay settings, so the panel keeps knowing nothing about UserDefaults.
        overlayBox.onSizeChanged = { [appearance] width, height in
            appearance.boxWidth = width
            appearance.boxHeight = height
        }
        // On by default, but the box is a session surface: this only arms the switch. It reaches the
        // screen on Start (below) and leaves it on Stop, so a stopped Jarvis shows nothing.
        overlayBox.setEnabled(appearance.boxEnabled)

        // No updater in a development bundle (no feed URL), so the menu omits the item entirely.
        updates = UpdateController()
        menuBar = MenuBarController(
            updateAvailability: updates.map { updater in { updater.canCheckForUpdates } },
            onCheckForUpdates: updates.map { updater in { updater.checkForUpdates() } })
        renderReadinessStatus(readiness.status)

        // The global hint hotkey is constructed before Settings so HotkeySection's closures (built
        // below) can already read/apply through it. `onRequest` is wired later, alongside the
        // rest of session lifecycle plumbing.
        if !appearance.boxEnabled {
            explanationPreferences.isEnabled = false
            codePreferences.isEnabled = false
        }
        // After normalization, not beside the other panel settings above: the panel must latch the
        // preference the rest of launch agrees on, not the one a disabled box is about to clear.
        overlayBox.setCodeEnabled(codePreferences.isEnabled)
        hotkeys = HotkeyController(preferences: hotkeyPreferences.filter {
            ($0.shortcut != .explainMore || explanationPreferences.isEnabled)
                && ($0.shortcut != .showCode || codePreferences.isEnabled)
        })

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
            onKeySaved: { [weak self] credential, key in
                self?.applySavedAPIKeyToRunningSession(credential: credential, key: key)
            })
        let hotkeySection = HotkeySection(
                preferences: hotkeyPreferences,
                explanationPreferences: explanationPreferences,
                codePreferences: codePreferences,
                onCodeChanged: { [weak self] in self?.refreshOptionalShortcut(.showCode) },
                boxEnabled: { [weak self] in self?.appearance.boxEnabled == true },
                onExplanationsChanged: { [weak self] in self?.refreshOptionalShortcut(.explainMore) },
                hasActiveHotkey: { [weak self] shortcut in
                    guard let self else { return false }
                    // Deferred bindings have no live registration to warn about until Start.
                    return (self.requestManualHint != nil && !self.sessionAllows(shortcut))
                        || self.hotkeys?.registered[shortcut] != nil
                },
                applyCombination: { [weak self] shortcut, combination in
                    // `hotkeys` is constructed above, before Settings can ever be shown, so `self`
                    // being torn down is the only way this falls through — report failure rather
                    // than falsely claiming a rebind that never happened.
                    guard let self else { return .failed(status: -1) }
                    let outcome = self.hotkeys?.apply(combination, for: shortcut) ?? .failed(status: -1)
                    if self.requestManualHint != nil, !self.sessionAllows(shortcut) {
                        self.hotkeys?.unregister(shortcut) // Validate ownership, then release until Start.
                    }
                    return outcome
                })
        let sections: [SettingsSection] = [
            brainSection,
            connectionsSection,
            OverlaySection(appearance: appearance, caption: overlayCaption, box: overlayBox,
                onBoxEnabledChanged: { [weak self] enabled in
                    guard let self, !enabled else { return }
                    self.explanationPreferences.isEnabled = false
                    self.codePreferences.isEnabled = false
                    self.overlayBox.setCodeEnabled(false)
                    self.hotkeys?.unregister(.explainMore)
                    self.hotkeys?.unregister(.showCode)
                }),
            DisplaySection(preferences: screenPreferences) { [weak self] in
                self?.reapplySessionPlan()
            },
            PrepMaterialSection(preferences: prepMaterialPreferences),
            hotkeySection,
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

        // While a session is running, screenshot + ask the brain for a hint in one trip; otherwise
        // beep — there's no live driver/conversation to hint from when stopped.
        hotkeys?.onRequest = { [weak self] shortcut in
            guard let self, let fire = self.requestManualHint else {
                NSSound.beep() // ghost-mode-allowed: explicit user hotkey while stopped
                return
            }
            guard self.sessionAllows(shortcut) else { return }
            fire(shortcut)
        }

        if !transcriptionPreferences.provider.requiredCredentials(
            for: brain.preferences.route
        ).allSatisfy({ secrets.apiKey(for: $0)?.isEmpty == false }) {
            jlog("Jarvis: missing an API key — paste it in Settings, then press Start.")
        } else {
            jlog("Jarvis: ready — press Start in the menu bar to begin coaching.")
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quitting from the permission gate happens before anything exists to stop.
        guard didStartApp else { return .terminateNow }
        activityViewer?.cancelEvaluation()
        stop(reason: .applicationQuit)
        return .terminateNow
    }








    /// Keep a healthy live conversation intact when the credential file changes. Existing Realtime
    /// sockets are already authenticated; retain them and use the new key only if either socket later
    /// reconnects. The transcription half is session runtime and stays here; the brain half is
    /// composition's, and it installs fresh OpenAI target clients between coaching attempts without
    /// probing or replacing CLI clients, changing route policy, or restarting transcription.
    ///
    /// Guarded by credential: a saved OpenAI key must never reach a Gemini-backed session (or vice
    /// versa). Each session applies only the credential it authenticates with and ignores the rest,
    /// so this passes the credential along rather than deciding on their behalf.
    private func applySavedAPIKeyToRunningSession(credential: Credential, key: String) {
        guard let transcriber else { return }
        transcriber.updateAPIKey(key, for: credential)
        themTranscriber?.updateAPIKey(key, for: credential)
        if credential == .openAIAPIKey { brain.applySavedAPIKey(key) }
    }

    /// Validate a Start immediately, then prove system audio and prepare any local-CLI targets and
    /// on-device speech assets.
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
        // Resolve once because CLI providers bake the prompt into their session. None adds nothing.
        let interviewFormat = brain.preferences.interviewFormat
        let interviewFormatAddendum = interviewFormat?.promptAddendum ?? ""
        let explanationsEnabled = explanationPreferences.isEnabled && appearance.boxEnabled
        let codeEnabled = codePreferences.isEnabled && appearance.boxEnabled
            && (interviewFormat == nil || interviewFormat == .coding || interviewFormat == .generalTechnical)
        let key = secrets.apiKey(for: .openAIAPIKey) ?? ""
        // The brain's key stays OpenAI-only (above); transcription reads whichever credential the
        // selected provider owns — Apple Speech has none, so this is "" there and unused.
        let transcriptionKey = transcriptionProvider.ownCredential
            .flatMap { secrets.apiKey(for: $0) } ?? ""
        let requiredCredentials = transcriptionProvider.requiredCredentials(for: brainRoute)
        let preparesAppleSpeech = transcriptionProvider == .appleSpeech
        // Only the readable grants gate a Start here: microphone live, screen recording from this
        // process's preflight. System audio is settled by the probe below, which is the only
        // authority on it — requiring the previous answer here would let one failed probe refuse
        // every later Start until Jarvis was relaunched, while the notice says to press Start again.
        let readinessConfiguration = JarvisReadiness.Configuration(
            requiredPermissions: PermissionGate.required.subtracting([.systemAudio]),
            requiredCredentials: requiredCredentials,
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

        let availableCredentials = Set(Credential.allCases.filter {
            secrets.apiKey(for: $0)?.isEmpty == false
        })
        observeReadiness(.credentials(available: availableCredentials), for: readinessSession)
        let missingCredentials = requiredCredentials.subtracting(availableCredentials)
        guard missingCredentials.isEmpty else {
            jlog("Jarvis: can't start — missing credential(s): "
                 + missingCredentials.map(\.rawValue).sorted().joined(separator: ", "))
            if wasRunning {
                artifacts.sessionAudit?.record(.settingsChangeNotApplied)
            }
            errorReporter.reportImmediately(
                .noAPIKey(missing: missingCredentials),
                context: reportContext)
            return false
        }

        pendingStartRevision &+= 1
        let revision = pendingStartRevision
        pendingStartTask?.cancel()
        pendingStartTask = nil
        let cliProviders = brainRoute.targets.map(\.provider).filter(\.usesLocalCLI)
        let detector = AgentCLIDetector()
        pendingStartTask = Task { [weak self] in
            guard let self else { return }

            // Prove system audio again for this session. The launch proof can be hours or days old
            // on a menu-bar app, and a grant withdrawn since would otherwise produce a session that
            // reports full readiness while hearing nothing: a refused tap still delivers frames, and
            // capture health counts frames without inspecting amplitude. Microphone and Screen
            // Recording need no probe — the checks above read them directly.
            guard await Permissions.request(.systemAudio, remembering: self.permissionPreferences)
            else {
                self.rejectStartWithoutSystemAudio(
                    revision: revision,
                    wasRunning: wasRunning,
                    context: reportContext,
                    readinessSession: readinessSession)
                return
            }

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
            let credentialIsCurrent = !requiredCredentials.contains(.openAIAPIKey)
                || (self.secrets.apiKey(for: .openAIAPIKey) ?? "") == key
            // Mirrors the OpenAI check above for whichever credential the transcription provider
            // itself owns (Gemini today; Apple Speech has none and is trivially current).
            let transcriptionCredentialIsCurrent = transcriptionProvider.ownCredential.map {
                (self.secrets.apiKey(for: $0) ?? "") == transcriptionKey
            } ?? true
            guard credentialIsCurrent, transcriptionCredentialIsCurrent,
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
                transcriptionKey: transcriptionKey,
                brainRoute: brainRoute,
                interviewFormatAddendum: interviewFormatAddendum,
                interviewFormat: interviewFormat,
                explanationsEnabled: explanationsEnabled,
                codeEnabled: codeEnabled,
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

    /// A Start whose system-audio proof failed. Distinct from a transcription blocker: the session
    /// never begins, and the notice names the permission rather than the provider.
    private func rejectStartWithoutSystemAudio(
        revision: UInt,
        wasRunning: Bool,
        context: UserFacingError.PresentationContext,
        readinessSession: JarvisReadiness.Session
    ) {
        guard pendingStartRevision == revision,
              self.readinessSession == readinessSession else { return }
        pendingStartTask = nil
        observeReadiness(
            .permissions(granted: Permissions.grantedReadinessPermissions()),
            for: readinessSession)
        jlog("Jarvis: can't start — system audio is no longer proved for this session.")
        if wasRunning {
            artifacts.sessionAudit?.record(.settingsChangeNotApplied)
        }
        errorReporter.reportImmediately(.permissionsMissing([.systemAudio]), context: context)
    }

    /// Install a fully prepared route on the main actor. The primary preflight still happens before
    /// tearing down a running pipeline, while unavailable fallback CLIs remain ordered skip targets.
    private func installPreparedStart(
        apiKey key: String,
        transcriptionKey: String,
        brainRoute: BrainRoute,
        interviewFormatAddendum: String,
        interviewFormat: InterviewFormat?,
        explanationsEnabled: Bool,
        codeEnabled: Bool,
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
        overlayBox.setInterviewFormat(interviewFormat)
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
        case .gemini:
            jlog("Jarvis transcription: provider=Gemini")
        }

        // Each target's coach and summarizer share the session traffic log. Every fresh attempt is a
        // distinct audit-visible request; no transport wrapper replays a failed request.
        let sessionDirectory = artifacts.currentSessionDir!
        // Fixed for the whole session — set before every construction/reapply path that bakes a
        // system prompt, including a later `applyBrainPreferencesToRunningSession` hot switch.
        sessionCodeEnabled = codeEnabled
        brain.codeEnabled = codeEnabled
        overlayBox.setCodeEnabled(codeEnabled)
        if codeEnabled, let preference = hotkeyPreferences.first(where: { $0.shortcut == .showCode }) {
            hotkeys?.apply(preference.combination, for: .showCode)
        } else {
            hotkeys?.unregister(.showCode)
        }
        sessionExplanationsEnabled = explanationsEnabled
        brain.explanationsEnabled = explanationsEnabled
        if explanationsEnabled, let preference = hotkeyPreferences.first(where: { $0.shortcut == .explainMore }) {
            hotkeys?.apply(preference.combination, for: .explainMore)
        } else {
            hotkeys?.unregister(.explainMore)
        }
        brain.interviewFormatAddendum = interviewFormatAddendum
        // One tool set for the session, handed to both the targets that bake it into their
        // instructions and the driver that sends it. Prep material counts as configured sources, not
        // a finished index: the index lands later and must not change what the session offers (#273).
        let prepMaterialSources = prepMaterialPreferences.sources
        let sessionTools = sessionCoachTools(
            interviewFormat: interviewFormat, prepMaterial: !prepMaterialSources.isEmpty)
        brain.coachTools = sessionTools
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
            activity: artifacts.sessionAudit,
            coachTools: sessionTools,
            interviewFormatAddendum: interviewFormatAddendum,
            interviewFormat: interviewFormat)

        // Building the index reads files and can shell out to `textutil`, so it runs off the Start
        // path entirely rather than delaying it — a search that fires before this lands returns no
        // matches for that one attempt. The tool itself was offered from Start, with the rest of the
        // session's fixed set. Tracked and cancelled in `stop()` for the same reason compaction is:
        // an untracked task would keep reading files and spawning textutil subprocesses after the
        // session it belongs to has already torn down.
        prepMaterialIndexTask = Task.detached(priority: .utility) { [weak driver] in
            let index = await PrepMaterialIndexBuilder.build(from: prepMaterialSources)
            guard !Task.isCancelled else { return }
            driver?.installPrepMaterial(index)
        }

        // CoachDriver is @unchecked Sendable; capture it (not @MainActor self) in the callbacks.
        // Route turns through TurnTaskBox so Stop can cancel an in-flight one. Concurrent triggers are
        // coalesced inside CoachDriver (the running turn batches them in), so we don't cancel here.
        let turns = TurnTaskBox()
        // "Me" side: the mic. Drives turn-end and the backing-off silence check ("are you stuck?").
        let transcriber = TranscriptionSessionFactory.make(
            configuration: transcriptionConfiguration,
            apiKey: transcriptionKey,
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
            apiKey: transcriptionKey,
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
        transcriber.onTerminalFailure = { [weak self, weak transcriber] failure in
            guard let transcriber else { return }
            Task { @MainActor [weak self] in
                guard let self, self.transcriber === transcriber else { return }
                self.reportTranscriptionFailure(failure)
            }
        }
        themTranscriber.onTerminalFailure = { [weak self, weak themTranscriber] failure in
            guard let themTranscriber else { return }
            Task { @MainActor [weak self] in
                guard let self, self.themTranscriber === themTranscriber else { return }
                // Key on the failure, not the provider: a socket transcriber (unlike Apple Speech)
                // can hit a rejected key, a denied region, or a connection that never came up on the
                // system-audio side too, and each of those threatens the mic side identically — see
                // `ProviderFailure.endsEverySession` for why degrading on one of those would hide
                // the real cause behind a misleading system-audio notice.
                if failure.endsEverySession {
                    self.reportTranscriptionFailure(failure)
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
                self.artifacts.sessionAudit?.record(.systemAudioStopped(failure: failure))
                self.errorReporter.reportImmediately(.systemAudioStopped, context: .runtime)
            }
        }

        // One-clock capture + echo cancellation: a single aggregate device (mic + system tap) feeds
        // the cleaned mic to the "me" socket and the sample-preserving system timeline to the "them"
        // socket, with AEC3 run inside its IOProc. If the device can't be built, the whole capture is
        // gone, so treat it as a full (mic-side) terminal failure.
        let localTurnDetectionSilenceDuration: TimeInterval? =
            transcriptionConfiguration.turnDetectionStrategy == .clientCommit
            ? TimeInterval(config.localEndpointSilenceDurationMs) / 1_000
            : nil
        let capture = AggregateEchoCapture(
            audioFormat: transcriptionConfiguration.provider.audioFormat,
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
                    .captureStopped(failure: Self.captureFailure(reason)), context: .runtime)
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
        self.requestManualHint = { shortcut in
            turns.run { await driver.handleTrigger(shortcut.triggerReason) }
        }
        transcriber.connect()
        themTranscriber.connect()
        if let reason = capture.start() {
            observeReadiness(.capture(.stopped), for: readinessSession)
            errorReporter.reportImmediately(
                .captureFailed(failure: Self.captureFailure(reason)), context: reportContext)
            return false
        }
        // Capture setup is synchronous and can legitimately take longer than the first-frame
        // deadline. Arm that deadline only after AudioDeviceStart succeeds; callbacks were installed
        // above, so any frame already queued on the main actor is still observed by this monitor.
        startCaptureReadiness(readinessSession: readinessSession)
        sessionIsLive = true
        // Show the (already cleared) history box, from the one place that declares the session live —
        // every earlier `return false` leaves the desktop untouched.
        overlayBox.setSessionLive(true)
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
        prepMaterialIndexTask?.cancel()
        prepMaterialIndexTask = nil
        let hadAllocatedPipeline = transcriber != nil || themTranscriber != nil
        let preservesReplacementReadiness = readinessToPreserve == readinessSession
        let preservesStartupBlock = !hadAllocatedPipeline
            && reason != .applicationQuit
            && readiness.status.isBlocked
        let endedLiveSession = sessionIsLive
        sessionIsLive = false
        overlayBox.setSessionLive(false)     // the history box goes away with the session
        requestManualHint = nil              // hotkey beeps again once there's no live session
        overlayBox.setCodeEnabled(false)
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

    /// Wrap a capture cause in the one failure record Activity and the session lifecycle read. The
    /// aggregate device is local, so there is no provider identity to carry: the sentence the
    /// capture layer already wrote is the whole evidence.
    private static func captureFailure(_ reason: String) -> ProviderFailure {
        ProviderFailure(
            source: .capture, stage: .local, category: .unavailable, disposition: .permanent,
            identity: .init(), message: reason)
    }

    /// Deduplicate endpoint failures: either side can fail first, but Activity should show one reason
    /// and teardown should run once.
    private func reportTranscriptionFailure(_ failure: ProviderFailure) {
        guard !reportedTranscriptionFailure, transcriber != nil || themTranscriber != nil else { return }
        reportedTranscriptionFailure = true
        // This method already runs on the main actor after checking the emitting transcriber's
        // identity. Deliver synchronously so Stop → Start cannot slip between that check and the
        // terminal lifecycle consequence and let a stale failure stop the replacement session.
        errorReporter.reportImmediately(
            .transcriptionStopped(failure: failure), context: .runtime)
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
                    .captureStopped(failure: Self.captureFailure(
                        "Jarvis stopped receiving microphone audio. Check the input device and press Start.")),
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
                artifacts.sessionAudit?.record(
                    .systemAudioStopped(failure: Self.captureFailure(cause.summary)))
                errorReporter.reportImmediately(.systemAudioStopped, context: .runtime)
            }
        }
    }



    private func sessionAllows(_ shortcut: CoachingShortcut) -> Bool {
        switch shortcut {
        case .hint: true
        case .explainMore: sessionExplanationsEnabled
        case .showCode: sessionCodeEnabled
        }
    }

    private func refreshOptionalShortcut(_ shortcut: CoachingShortcut) {
        let enabled = shortcut == .explainMore ? explanationPreferences.isEnabled : codePreferences.isEnabled
        if enabled, requestManualHint == nil || sessionAllows(shortcut),
           let preference = hotkeyPreferences.first(where: { $0.shortcut == shortcut }) {
            hotkeys?.apply(preference.combination, for: shortcut)
        } else {
            hotkeys?.unregister(shortcut)
        }
    }

    /// Read the persisted control plane once and freeze it as the next revision.
    ///
    /// This is the only place preferences reach a coaching attempt. Everything a turn needs is
    /// resolved here, at Start or at an explicit Settings boundary, so no attempt reads storage
    /// (wiki/lean-coaching-core.md, Phase 4).
    private func freshSessionPlan() -> SessionPlan {
        planRevision &+= 1
        return SessionPlan(revision: planRevision, screen: screenPreferences.selection,
                           explanationsEnabled: sessionExplanationsEnabled, codeEnabled: sessionCodeEnabled)
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
