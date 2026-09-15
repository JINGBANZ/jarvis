import AppKit
import JarvisBrainProviders
import JarvisCore
import JarvisEvaluation
import JarvisOverlay

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, BrainCompositionHost {
    private let secretFile = FileSecretStore()
    private lazy var secrets = ChainedSecretStore([secretFile, EnvSecretStore()])
    /// The single funnel for user-facing failures (alerts + fatal session teardown). See `ErrorReporter`.
    private let errorReporter = ErrorReporter()

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
    /// The bundled helper serving the subscription targets: started when first needed, stopped at
    /// Quit. Nil until the app starts past the permission gate.
    private var proxySupervisor: LocalProxySupervisor?
    /// The session runtime: everything between an accepted Start and coaching ready, and Stop.
    /// Built once the app's surfaces exist; every Start and Stop runs on it.
    private var composition: SessionComposition!
    private let transcriptionPreferences = TranscriptionPreferences()
    private let screenPreferences = ScreenCapturePreferences()
    private let prepMaterialPreferences = PrepMaterialPreferences()
    private let permissionPreferences = PermissionPreferences()
    private var permissionGate: PermissionGate!
    /// Whether the app's own surfaces exist yet. Nothing is built while the permission gate is up.
    private var didStartApp = false
    private let explanationPreferences = ExplanationPreferences()
    private let codePreferences = CodePreferences()
    private let hotkeyPreferences = CoachingShortcut.allCases.map { HotkeyPreferences(shortcut: $0) }
    private var activityViewer: ActivityViewer!    // embedded as the Settings Activity tab
    /// Overall readiness is composed in Core. Its `activeSession` is the one token for the attempt
    /// being started or run; the App feeds it OS and provider observations.
    private let readiness = JarvisReadiness()
    /// A Start that is still preparing its session. Stop or a newer Start cancels it before the
    /// prepared runtime can be installed on the main actor.
    private var pendingStartTask: Task<Void, Never>?
    private var pendingStartRevision: UInt = 0
    /// The global hint hotkey. Lives for the whole app run; its callback beeps when no session runs.
    private var hotkeys: HotkeyController?
    /// Everything this session leaves on disk: the owner-only directory, the evidence handle in it,
    /// retention pruning, and the close bookkeeping. See `SessionArtifacts` for the boundary.
    private let artifacts = SessionArtifacts()

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
        let supervisor = LocalProxySupervisor(
            executable: LocalProxySupervisor.bundledExecutable(),
            home: secretFile.directoryURL.appendingPathComponent("proxy", isDirectory: true))
        proxySupervisor = supervisor
        brain = BrainComposition(secrets: secrets, host: self, supervisor: supervisor)
        // A saved route that coaches on a subscription finds the helper answering by its first Start.
        if brain.preferences.route.targets.contains(where: { $0.provider.servedByLocalProxy }) {
            Task { await supervisor.ensureRunning() }
        }

        // The activity viewer lives for the whole app run, but a *session* is one coaching run: each
        // Start opens a fresh session dir + logs (see `beginNewSession`). No session exists until the
        // first Start, so the viewer starts with no current session to browse.
        activityViewer = ActivityViewer(log: .shared,
                                        store: SessionStore(base: artifacts.logDirectory(), current: nil))
        // Evaluation/report opening is explicit Activity UI and remains unavailable while coaching
        // runs—or while a cancelled turn is still draining—so it cannot reveal Jarvis during the
        // ghost lifecycle.
        activityViewer.isCoachingRunning = { [weak self] in
            self?.composition?.isCoachingRunning ?? false
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
        // source at click time, so a moved local app bundle is reflected without rebuilding Activity.
        activityViewer.makeEvaluator = { [weak self] session in
            guard let self else { return nil }
            return AgenticEvaluator(source: self.artifacts.evaluationSource(for: session))
        }

        overlayCaption = OverlayCaptionPanel()
        overlayCaption.setFontSize(appearance.captionFontSize)
        overlayCaption.setBackgroundOpacity(appearance.captionBackgroundOpacity)
        overlayCaption.setEnabled(appearance.captionEnabled)   // off by default

        overlayBox = OverlayBoxPanel(contentSize: NSSize(
            width: appearance.boxWidth, height: appearance.boxHeight))
        overlayBox.setFontSize(appearance.boxFontSize)
        overlayBox.setOpacity(appearance.boxOpacity)
        overlayBox.setCodeFontSize(appearance.codeFontSize)
        overlayBox.setCodeBackgroundOpacity(appearance.codeBackgroundOpacity)
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

        composition = SessionComposition(
            brain: brain,
            artifacts: artifacts,
            overlayCaption: overlayCaption,
            overlayBox: overlayBox,
            readiness: readiness,
            errorReporter: errorReporter,
            // One-clock capture + echo cancellation: a single private aggregate device (built-in mic
            // + system-output tap on one drift-compensated clock) feeds the cleaned mic to the "me"
            // socket and the sample-preserving system timeline to the "them" socket, with AEC3 run
            // inside its IOProc.
            makeAudioSource: { audioFormat, localTurnDetectionSilenceDuration, delivery in
                AggregateEchoCapture(
                    audioFormat: audioFormat,
                    localTurnDetectionSilenceDuration: localTurnDetectionSilenceDuration,
                    delivery: delivery)
            })
        composition.onReadinessStatusChanged = { [weak self] status in
            self?.renderReadinessStatus(status)
        }
        composition.onCoachingStateChanged = { [weak self] in
            self?.activityViewer?.coachingStateDidChange()
        }

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
            supervisor: supervisor,
            onPreferencesChanged: { [weak self] change in
                Task {
                    await self?.brain.applyBrainPreferencesToRunningSession(
                        update: change == .topology ? .topologyEdit : .effortEdit)
                }
            },
            transcriptionPreferences: transcriptionPreferences,
            prepMaterialPreferences: prepMaterialPreferences)
        let connectionsSection = ConnectionsSection(
            supervisor: supervisor,
            keyStore: secretFile,
            onKeySaved: { [weak self] credential, key in
                self?.composition.applySavedAPIKey(key, for: credential)
            })
        let hotkeySection = HotkeySection(
                preferences: hotkeyPreferences,
                explanationPreferences: explanationPreferences,
                codePreferences: codePreferences,
                boxEnabled: { [weak self] in self?.appearance.boxEnabled == true },
                onExplanationsChanged: { [weak self] in self?.refreshOptionalShortcut(.explainMore) },
                hasActiveHotkey: { [weak self] shortcut in
                    guard let self else { return false }
                    // Deferred bindings have no live registration to warn about until Start.
                    return (self.composition.isLive && !self.composition.allows(shortcut))
                        || self.hotkeys?.registered[shortcut] != nil
                },
                applyCombination: { [weak self] shortcut, combination in
                    // `hotkeys` is constructed above, before Settings can ever be shown, so `self`
                    // being torn down is the only way this falls through — report failure rather
                    // than falsely claiming a rebind that never happened.
                    guard let self else { return .failed(status: -1) }
                    let outcome = self.hotkeys?.apply(combination, for: shortcut) ?? .failed(status: -1)
                    if (shortcut == .showCode && !self.codePreferences.isEnabled)
                        || (self.composition.isLive && !self.composition.allows(shortcut)) {
                        self.hotkeys?.unregister(shortcut) // Validate ownership, then release until Start.
                    }
                    return outcome
                })
        let sections: [SettingsSection] = [
            brainSection,
            connectionsSection,
            OverlaySection(appearance: appearance, caption: overlayCaption, box: overlayBox,
                codePreferences: codePreferences,
                onCodeChanged: { [weak self] in self?.refreshOptionalShortcut(.showCode) },
                onBoxEnabledChanged: { [weak self] enabled in
                    guard let self, !enabled else { return }
                    self.explanationPreferences.isEnabled = false
                    self.codePreferences.isEnabled = false
                    self.overlayBox.setCodeEnabled(false)
                    self.hotkeys?.unregister(.explainMore)
                    self.hotkeys?.unregister(.showCode)
                }),
            DisplaySection(
                preferences: screenPreferences,
                isSessionStopped: { [weak self] in
                    guard let self else { return false }
                    return self.pendingStartTask == nil
                        && !self.composition.hasAllocatedPipeline
                        && !self.composition.isCoachingRunning
                },
                onChange: { [weak self] in
                    guard let self else { return }
                    self.composition.updateScreenSelection(self.screenPreferences.selection)
                }),
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

        // While a session is running, screenshot + ask the brain for a hint; otherwise
        // beep — there's no live driver/conversation to hint from when stopped.
        hotkeys?.onRequest = { [weak self] shortcut in
            guard let self, self.composition.isLive else {
                NSSound.beep() // ghost-mode-allowed: explicit user hotkey while stopped
                return
            }
            guard self.composition.allows(shortcut) else { return }
            self.composition.requestShortcut(shortcut)
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
        proxySupervisor?.terminateNow()
        return .terminateNow
    }

    /// Validate a Start immediately, then prove system audio, read the subscription helper, and
    /// prepare on-device speech assets.
    /// Returns `true` once startup is accepted; the menu remains in Starting until preparation and
    /// both transcription endpoints finish. Stop, a newer Start, or a relevant preference/credential
    /// edit makes the prepared result stale before it can install a pipeline.
    @discardableResult
    private func start() -> Bool {
        let wasRunning = composition.hasAllocatedPipeline
        let reportContext: UserFacingError.PresentationContext =
            wasRunning ? .runtime : .startup
        let transcriptionConfiguration = transcriptionPreferences.configuration
        let transcriptionProvider = transcriptionConfiguration.provider
        let brainRoute = brain.preferences.route
        let explanationsEnabled = explanationPreferences.isEnabled && appearance.boxEnabled
        let codeEnabled = codePreferences.isEnabled && appearance.boxEnabled
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
        composition.applyReadinessEffects(readinessStart.effects)

        let grantedPermissions = Permissions.grantedReadinessPermissions()
        composition.observeReadiness(.permissions(granted: grantedPermissions), for: readinessSession)
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
        composition.observeReadiness(
            .credentials(available: availableCredentials), for: readinessSession)
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
                      self.readiness.activeSession == readinessSession else { return }
                self.composition.observeReadiness(
                    .transcriptionPreparation(.ready), for: readinessSession)
            }
            let proxy = await self.brain.proxyReadiness(for: brainRoute)
            guard !Task.isCancelled,
                  self.pendingStartRevision == revision,
                  self.readiness.activeSession == readinessSession else {
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
            _ = self.installPreparedStart(
                apiKey: key,
                transcriptionKey: transcriptionKey,
                brainRoute: brainRoute,
                explanationsEnabled: explanationsEnabled,
                codeEnabled: codeEnabled,
                transcriptionConfiguration: transcriptionConfiguration,
                appleSpeechLocale: appleSpeechLocale,
                proxy: proxy,
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
              readiness.activeSession == readinessSession else { return }
        pendingStartTask = nil
        composition.observeReadiness(
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
              readiness.activeSession == readinessSession else { return }
        pendingStartTask = nil
        composition.observeReadiness(
            .permissions(granted: Permissions.grantedReadinessPermissions()),
            for: readinessSession)
        jlog("Jarvis: can't start — system audio is no longer proved for this session.")
        if wasRunning {
            artifacts.sessionAudit?.record(.settingsChangeNotApplied)
        }
        errorReporter.reportImmediately(.permissionsMissing([.systemAudio]), context: context)
    }

    /// Install a fully prepared route on the main actor. A route with no usable target is refused
    /// before tearing down a running pipeline; an unusable subscription stays in it as a skip target.
    private func installPreparedStart(
        apiKey key: String,
        transcriptionKey: String,
        brainRoute: BrainRoute,
        explanationsEnabled: Bool,
        codeEnabled: Bool,
        transcriptionConfiguration: TranscriptionConfiguration,
        appleSpeechLocale: Locale?,
        proxy: LocalProxySupervisor.Readiness?,
        wasRunning: Bool,
        reportContext: UserFacingError.PresentationContext,
        readinessSession: JarvisReadiness.Session
    ) -> Bool {
        guard readiness.activeSession == readinessSession else { return false }
        // A signed-out or unserved subscription is skipped when the route reaches it, so a later
        // target can still coach. Only a route with no target left is refused here.
        if let failure = brain.routeUnavailability(brainRoute, proxy: proxy) {
            jlog("Jarvis: can't start — no target in the route can coach: "
                 + (failure.errorDescription ?? ""))
            if wasRunning {
                artifacts.sessionAudit?.record(.settingsChangeNotApplied)
            }
            errorReporter.reportImmediately(.brainRouteUnavailable(failure: failure), context: reportContext)
            composition.observeReadiness(
                .brainPreparation(.blocked(.providerUnavailable)),
                for: readinessSession)
            return false
        }
        stop(reason: .replacedByNewSession, preserving: readinessSession)
        // The optional shortcuts follow the switches this session is frozen with.
        if codeEnabled, let preference = hotkeyPreferences.first(where: { $0.shortcut == .showCode }) {
            hotkeys?.apply(preference.combination, for: .showCode)
        } else {
            hotkeys?.unregister(.showCode)
        }
        if explanationsEnabled, let preference = hotkeyPreferences.first(where: { $0.shortcut == .explainMore }) {
            hotkeys?.apply(preference.combination, for: .explainMore)
        } else {
            hotkeys?.unregister(.explainMore)
        }
        brainSection.setActiveTarget(brainRoute.primary)
        return composition.start(
            SessionComposition.Inputs(
                transcription: transcriptionConfiguration,
                transcriptionKey: transcriptionKey,
                brainAPIKey: key,
                brainRoute: brainRoute,
                appleSpeechLocale: appleSpeechLocale,
                screen: screenPreferences.selection,
                prepSources: prepMaterialPreferences.sources,
                explanationsEnabled: explanationsEnabled,
                codeEnabled: codeEnabled),
            proxy: proxy,
            readinessSession: readinessSession,
            reportContext: reportContext)
    }

    /// Cancel any pending Start, tear the session down through the composition, and settle the
    /// readiness attempt. Safe to call when already stopped.
    private func stop(
        reason: SessionEndReason,
        preserving readinessToPreserve: JarvisReadiness.Session? = nil
    ) {
        pendingStartRevision &+= 1
        pendingStartTask?.cancel()
        pendingStartTask = nil
        // A blocker a Start reported before allocating anything stays on screen until the next
        // explicit Start; a replacement Start keeps the readiness attempt it just began.
        let preservesStartupBlock = !composition.hasAllocatedPipeline
            && reason != .applicationQuit
            && readiness.status.isBlocked
        composition.stop(reason: reason)
        brainSection?.setActiveTarget(nil)
        if !preservesStartupBlock,
           let readinessSession = readiness.activeSession,
           readinessSession != readinessToPreserve {
            composition.applyReadinessEffects(readiness.stop(session: readinessSession))
        }
    }

    // MARK: - BrainCompositionHost

    /// What brain composition may see of the live session, and how it reports back. Read-only
    /// accessors and presentation forwards — composition never starts, stops, or tears down.
    var liveCoachDriver: CoachDriver? { composition?.coachDriver }
    var liveSessionDirectory: URL? { artifacts.currentSessionDir }
    var liveSessionEvidence: FileSessionAudit? { artifacts.sessionAudit }
    var isTranscriptionLive: Bool { composition?.isTranscriptionLive ?? false }

    func reportBrainError(
        _ error: UserFacingError, context: UserFacingError.PresentationContext
    ) {
        errorReporter.reportImmediately(error, context: context)
    }

    func brainRecoveryDidChange(_ provider: BrainProvider?) {
        composition.brainRecoveryDidChange(provider)
    }

    func brainCycleDidFail(_ provider: BrainProvider) {
        composition.brainCycleDidFail(provider)
    }

    func brainTargetDidChange(_ target: BrainTarget?) {
        brainSection.setActiveTarget(target)
    }

    private func renderReadinessStatus(_ status: JarvisReadiness.Status) {
        menuBar?.setStatus(status)
        activityViewer?.readinessDidChange(status)
    }

    private func cancelReadinessAttempt(_ session: JarvisReadiness.Session) {
        guard readiness.activeSession == session else { return }
        composition.applyReadinessEffects(readiness.stop(session: session))
    }

    private func refreshOptionalShortcut(_ shortcut: CoachingShortcut) {
        let enabled = shortcut == .explainMore ? explanationPreferences.isEnabled : codePreferences.isEnabled
        if enabled, !composition.isLive || composition.allows(shortcut),
           let preference = hotkeyPreferences.first(where: { $0.shortcut == shortcut }) {
            hotkeys?.apply(preference.combination, for: shortcut)
        } else {
            hotkeys?.unregister(shortcut)
        }
    }
}

private extension JarvisReadiness.Status {
    var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }
}
