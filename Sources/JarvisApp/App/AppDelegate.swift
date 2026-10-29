import AppKit
import JarvisProcess
import JarvisBrainProviders
import JarvisCore
import JarvisEvaluation
import JarvisOverlay

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, BrainCompositionHost {
    private let secretFile = FileSecretStore()
    private lazy var secrets = ChainedSecretStore([secretFile, EnvSecretStore()])
    private let errorReporter = ErrorReporter()

    private var overlayBox: OverlayBoxPanel!
    private var menuBar: MenuBarController!
    /// Nil in a development bundle, which has no Sparkle feed URL.
    private var updates: UpdateController?
    private var settingsWindow: SettingsWindow!
    private var brainSection: BrainSection!
    private var settingsHub: SettingsHubModel!
    private var settingsHome: SettingsHome!
    private let appearance = OverlayAppearance()
    private var brain: BrainComposition!
    private var proxySupervisor: LocalProxySupervisor?
    private var composition: SessionComposition!
    private let transcriptionPreferences = TranscriptionPreferences()
    private let screenPreferences = ScreenCapturePreferences()
    private let referencePreferences = ReferencePreferences()
    private let permissionPreferences = PermissionPreferences()
    private let onboardingPreferences = OnboardingPreferences()
    private var onboarding: OnboardingGate!
    private var didStartApp = false
    private let hotkeyPreferences = CoachingShortcut.allCases.map { HotkeyPreferences(shortcut: $0) }
    private var activityViewer: ActivityViewer!
    private let readiness = JarvisReadiness()
    private var pendingStartTask: Task<Void, Never>?
    private var pendingReferenceAdmission: PendingReferenceAdmission?
    private var pendingStartRevision: UInt = 0
    private var hotkeys: HotkeyController?
    private var mouseHotkeys: MouseHotkeyController?
    private let artifacts = SessionArtifacts()
    private let launcher: any ProcessLaunching
    private let references: ReferenceRuntime
    private var terminatingReferences = false

    init(launcher: any ProcessLaunching) {
        self.launcher = launcher
        self.references = ReferenceRuntime(launcher: launcher)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // ghost-mode-allowed: launch configuration
        MainMenu.install()
        configureReferences()

        onboarding = OnboardingGate(
            preferences: onboardingPreferences,
            permissionPreferences: permissionPreferences,
            secrets: secrets,
            keyStore: secretFile,
            brainPreferences: BrainPreferences(),
            transcriptionPreferences: transcriptionPreferences)
        onboarding.onFinished = { [weak self] in self?.startApp() }
        // Async: proving the system-audio grant runs a tap, which must not block the main thread.
        Task { @MainActor [weak self] in
            await self?.onboarding.begin()
        }
    }

    private func startApp() {
        guard !terminatingReferences else { return }
        didStartApp = true
        let supervisor = LocalProxySupervisor(
            executable: LocalProxySupervisor.bundledExecutable(),
            home: secretFile.directoryURL.appendingPathComponent("proxy", isDirectory: true),
            launcher: launcher)
        proxySupervisor = supervisor
        brain = BrainComposition(secrets: secrets, host: self, supervisor: supervisor)
        if brain.preferences.route.targets.contains(where: { $0.provider.servedByLocalProxy }) {
            Task { await supervisor.ensureRunning() }
        }

        activityViewer = ActivityViewer(
            log: .shared, store: SessionStore(base: artifacts.logDirectory(), current: nil),
            launcher: launcher)
        // Ghost mode: evaluation UI stays unavailable while coaching runs or a cancelled turn
        // drains, so it can't reveal Jarvis.
        activityViewer.isCoachingRunning = { [weak self] in
            self?.composition?.isCoachingRunning ?? false
        }
        activityViewer.isSessionAuditClosed = { [weak self] directory in
            self?.artifacts.isAuditClosed(for: directory) ?? true
        }
        activityViewer.protectedSessionDirectories = { [weak self] in
            self?.artifacts.protectedAuditDirectories() ?? []
        }
        artifacts.onSessionDidChange = { [weak self] base, current in
            self?.activityViewer.sessionDidChange(base: base, current: current)
        }
        artifacts.onHistoryDidChange = { [weak self] in
            self?.activityViewer?.historyDidChange()
        }
        // Resolved at click time, so a moved app bundle is picked up without rebuilding Activity.
        activityViewer.makeEvaluator = { [weak self] session, cli in
            guard let self else { return nil }
            return AgenticEvaluator(source: self.artifacts.evaluationSource(for: session),
                                    preferredCLI: cli, launcher: self.launcher)
        }

        overlayBox = OverlayBoxPanel(contentSize: NSSize(
            width: appearance.boxWidth, height: appearance.boxHeight))
        overlayBox.setFontSize(appearance.boxFontSize)
        overlayBox.setOpacity(appearance.boxOpacity)
        overlayBox.setDetailFontSize(appearance.detailFontSize)
        overlayBox.setDetailBackgroundOpacity(appearance.detailBackgroundOpacity)
        overlayBox.onSizeChanged = { [appearance] width, height in
            appearance.boxWidth = width
            appearance.boxHeight = height
        }

        composition = SessionComposition(
            brain: brain,
            referenceLibrary: references.library,
            artifacts: artifacts,
            overlayBox: overlayBox,
            readiness: readiness,
            errorReporter: errorReporter,
            launcher: launcher,
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

        updates = UpdateController()
        menuBar = MenuBarController(
            updateAvailability: updates.map { updater in { updater.canCheckForUpdates } },
            onCheckForUpdates: updates.map { updater in { updater.checkForUpdates() } })
        renderReadinessStatus(readiness.status)

        // Built before Settings, whose hotkey closures apply through it.
        hotkeys = HotkeyController(preferences: hotkeyPreferences)

        let signIns = SubscriptionSignIns(supervisor: supervisor)
        brain.onProxyReadiness = { [weak signIns] in signIns?.record($0) }
        brain.onSubscriptionFailure = { [weak signIns] in signIns?.refresh(replacingPending: true) }
        brainSection = BrainSection(
            preferences: brain.preferences,
            signIns: signIns,
            onPreferencesChanged: { [weak self] change in
                Task {
                    await self?.brain.applyBrainPreferencesToRunningSession(
                        update: change == .topology ? .topologyEdit : .effortEdit)
                }
            })
        let connectionsSection = ConnectionsSection(
            keyStore: secretFile,
            signIns: signIns,
            onKeySaved: { [weak self] credential, key in
                self?.composition.applySavedAPIKey(key, for: credential)
                // A saved key writes a file, not UserDefaults, so nothing else would re-judge the hub.
                self?.settingsHub.refresh(probe: false)
            },
            onSubscriptionWillSignOut: { [weak self] provider in
                self?.cancelPendingStart(using: provider)
            })
        let mouseHotkeys = MouseHotkeyController(preferences: hotkeyPreferences)
        self.mouseHotkeys = mouseHotkeys
        mouseHotkeys.isEnabled = { [weak self] _ in self?.composition.isLive == true }
        mouseHotkeys.onRequest = { [weak self] shortcut in self?.hotkeys?.onRequest?(shortcut) }
        let hotkeySection = HotkeySection(
                preferences: hotkeyPreferences,
                mouseController: mouseHotkeys,
                hasActiveHotkey: { [weak self] shortcut in
                    self?.hotkeys?.registered[shortcut] != nil
                },
                applyCombination: { [weak self] shortcut, combination in
                    // Only a torn-down self reaches the fallback; report failure, not a rebind.
                    self?.hotkeys?.apply(combination, for: shortcut) ?? .failed(status: -1)
                })
        let sections: [SettingsSection] = [
            brainSection,
            TranscriptionSection(preferences: transcriptionPreferences),
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
            OverlaySection(appearance: appearance, box: overlayBox),
            connectionsSection,
            ToolsSection(brainPreferences: brain.preferences, referencePreferences: referencePreferences, onChanged: { [weak self] in self?.configureReferences() }),
            SkillsSection(preferences: brain.preferences),
            GeneralSection(preferences: brain.preferences, shortcuts: hotkeySection),
            ActivitySection(viewer: activityViewer),
        ]
        settingsHub = SettingsHubModel(
            brainPreferences: brain.preferences,
            transcriptionPreferences: transcriptionPreferences,
            screenPreferences: screenPreferences,
            appearance: appearance,
            secrets: secrets,
            signIns: signIns)
        settingsHome = SettingsHome(model: settingsHub)
        settingsWindow = SettingsWindow(home: settingsHome, sections: sections, hub: settingsHub)
        menuBar.onOpenSettings = { [weak self] in self?.settingsWindow.show() }

        menuBar.onStart = { [weak self] in self?.start() ?? false }
        menuBar.onStop = { [weak self] in self?.stop(reason: .stoppedByUser) }

        errorReporter.onFatal = { [weak self] reason in
            self?.stop(reason: reason)
        }

        hotkeys?.onRequest = { [weak self] shortcut in
            guard let self else { return }
            guard self.composition.isLive else {
                if shortcut.triggerReason != nil || shortcut == .newSession {
                    NSSound.beep() // ghost-mode-allowed: explicit user coaching hotkey while stopped
                }
                return
            }
            switch shortcut {
            case .previousDetail: self.overlayBox.showPreviousDetail()
            case .nextDetail: self.overlayBox.showNextDetail()
            case .collapseOverlay: self.overlayBox.toggleCollapse()
            // A Start while live is the existing replacement path: the old session keeps coaching
            // until the new one is prepared, then ends as `.replacedByNewSession`.
            case .newSession: self.start()
            case .hint, .explainMore, .showCode: self.composition.requestShortcut(shortcut)
            }
        }

        if Onboarding.needsAPIKey(secrets: secrets, brain: brain.preferences, transcription: transcriptionPreferences) {
            jlog("Jarvis: missing an API key — paste it in Settings, then press Start.")
        } else {
            jlog("Jarvis: ready — press Start in the menu bar to begin coaching.")
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminatingReferences else { return .terminateLater }
        terminatingReferences = true
        onboarding?.stop()
        if didStartApp {
            activityViewer?.cancelEvaluation()
            stop(reason: .applicationQuit)
            proxySupervisor?.terminateNow()
        }
        Task {
            await references.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func configureReferences() {
        references.configure(preferences: BrainPreferences(), sources: referencePreferences)
    }

    /// True once the Start is accepted, before preparation finishes. Stop, a newer Start, or a
    /// relevant preference or credential edit can still discard it.
    @discardableResult
    private func start() -> Bool {
        let wasRunning = composition.hasAllocatedPipeline
        let reportContext: UserFacingError.PresentationContext =
            wasRunning ? .runtime : .startup
        let transcriptionConfiguration = transcriptionPreferences.configuration
        let transcriptionProvider = transcriptionConfiguration.provider
        let brainRoute = brain.preferences.route
        let saveConversations = brain.preferences.saveConversations
        let brainKeys = brain.savedKeys(for: brainRoute)
        let transcriptionKey = transcriptionProvider.ownCredential
            .flatMap { secrets.apiKey(for: $0) } ?? ""
        let requiredCredentials = Set([transcriptionProvider.ownCredential].compactMap { $0 })
        let preparesAppleSpeech = transcriptionProvider == .appleSpeech
        let readinessConfiguration = JarvisReadiness.Configuration(
            requiredCredentials: requiredCredentials,
            requiresTranscriptionPreparation: preparesAppleSpeech)
        pendingStartRevision &+= 1
        pendingStartTask?.cancel()
        pendingStartTask = nil
        cancelPendingReferenceAdmission()
        let readinessStart = readiness.begin(configuration: readinessConfiguration)
        let readinessSession = readinessStart.session
        composition.applyReadinessEffects(readinessStart.effects)

        if let failure = brainRoute.credentialFailure(available: Set(brainKeys.keys)) {
            jlog("Jarvis: can't start — no target in the route can coach: "
                 + (failure.errorDescription ?? ""))
            if wasRunning {
                artifacts.sessionAudit?.record(.settingsChangeNotApplied)
            }
            composition.observeReadiness(
                .brainPreparation(.blocked(.providerUnavailable(failure))),
                for: readinessSession)
            return false
        }

        let grantedPermissions = Permissions.grantedReadinessPermissions()
        // A previous system-audio answer cannot gate Start; only the fresh probe can prove it.
        let missingPermissions = readinessConfiguration.requiredPermissions
            .subtracting([.systemAudio])
            .subtracting(grantedPermissions)
        guard missingPermissions.isEmpty else {
            composition.observeReadiness(
                .permissions(granted: grantedPermissions), for: readinessSession)
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

        let revision = pendingStartRevision
        let referenceStartID = UUID()
        let referenceDeadline = ContinuousClock.now + .seconds(2)
        references.reconcile()
        let referenceTask = PendingReferenceAdmission(library: references.library, deadline: referenceDeadline, startID: referenceStartID)
        pendingReferenceAdmission = referenceTask
        pendingStartTask = nil
        pendingStartTask = Task { [weak self] in
            guard let self else { return }
            defer {
                referenceTask.cancel()
                self.references.library.abandon(startID: referenceStartID)
                if self.pendingReferenceAdmission?.startID == referenceStartID { self.pendingReferenceAdmission = nil }
            }

            // Re-prove per session: a revoked grant's tap still delivers silent frames, and capture
            // health counts frames, not amplitude.
            let systemAudioGranted = await Permissions.request(
                .systemAudio, remembering: self.permissionPreferences)
            guard !Task.isCancelled,
                  self.pendingStartRevision == revision,
                  self.readiness.activeSession == readinessSession else { return }
            guard systemAudioGranted else {
                self.rejectStartWithoutSystemAudio(
                    revision: revision,
                    wasRunning: wasRunning,
                    context: reportContext,
                    readinessSession: readinessSession)
                return
            }
            self.composition.observeReadiness(
                .permissions(granted: Permissions.grantedReadinessPermissions()),
                for: readinessSession)

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
            let proxy = await self.brain.proxyReadiness(for: brainRoute, preparingStart: true)
            guard !Task.isCancelled,
                  self.pendingStartRevision == revision,
                  self.readiness.activeSession == readinessSession else {
                return
            }
            // A key saved while Start was preparing makes the prepared keys stale.
            let brainKeysAreCurrent = self.brain.savedKeys(for: brainRoute) == brainKeys
            let transcriptionCredentialIsCurrent = transcriptionProvider.ownCredential.map {
                (self.secrets.apiKey(for: $0) ?? "") == transcriptionKey
            } ?? true
            guard brainKeysAreCurrent, transcriptionCredentialIsCurrent,
                  proxy != .superseded,
                  self.transcriptionPreferences.configuration == transcriptionConfiguration,
                  self.brain.preferences.route == brainRoute else {
                self.pendingStartTask = nil
                self.cancelReadinessAttempt(readinessSession)
                return
            }
            let referenceAdmission: ReferenceAdmissionResult
            do { referenceAdmission = try await referenceTask.result() } catch { return }
            guard !Task.isCancelled, self.pendingStartRevision == revision,
                  self.readiness.activeSession == readinessSession else { return }
            guard self.brain.savedKeys(for: brainRoute) == brainKeys,
                  transcriptionProvider.ownCredential.map({ (self.secrets.apiKey(for: $0) ?? "") == transcriptionKey }) ?? true,
                  self.transcriptionPreferences.configuration == transcriptionConfiguration,
                  self.brain.preferences.route == brainRoute else {
                self.pendingStartTask = nil
                self.cancelReadinessAttempt(readinessSession)
                return
            }
            self.pendingStartTask = nil
            if let proxy { self.brain.onProxyReadiness?(proxy) }
            _ = self.installPreparedStart(
                references: referenceAdmission,
                brainKeys: brainKeys,
                transcriptionKey: transcriptionKey,
                brainRoute: brainRoute,
                saveConversations: saveConversations,
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
        let error: UserFacingError = Permissions.systemAudioProof == nil
            ? .systemAudioCheckFailed : .permissionsMissing([.systemAudio])
        errorReporter.reportImmediately(error, context: context)
    }

    /// Refuses a route with no usable target before stopping the running pipeline.
    private func installPreparedStart(
        references: ReferenceAdmissionResult,
        brainKeys: [Credential: String],
        transcriptionKey: String,
        brainRoute: BrainRoute,
        saveConversations: Bool,
        transcriptionConfiguration: TranscriptionConfiguration,
        appleSpeechLocale: Locale?,
        proxy: LocalProxySupervisor.Readiness?,
        wasRunning: Bool,
        reportContext: UserFacingError.PresentationContext,
        readinessSession: JarvisReadiness.Session
    ) -> Bool {
        guard readiness.activeSession == readinessSession else { return false }
        let availability = brain.availability(for: brainRoute, proxy: proxy, keys: brainKeys)
        if let failure = availability.blockingFailure {
            jlog("Jarvis: can't start — no target in the route can coach: "
                 + (failure.errorDescription ?? ""))
            if wasRunning {
                artifacts.sessionAudit?.record(.settingsChangeNotApplied)
            }
            composition.observeReadiness(
                .brainPreparation(.blocked(.providerUnavailable(failure))),
                for: readinessSession)
            return false
        }
        stop(reason: .replacedByNewSession, preserving: readinessSession, preservingReferenceStart: references.startID)
        showActiveBrainTarget(
            availability.failure(for: brainRoute.primary) == nil ? brainRoute.primary : nil)
        return composition.start(
            SessionComposition.Inputs(
                transcription: transcriptionConfiguration,
                transcriptionKey: transcriptionKey,
                brainKeys: brainKeys,
                brainRoute: brainRoute,
                saveConversations: saveConversations,
                appleSpeechLocale: appleSpeechLocale,
                screen: screenPreferences.selection,
                references: references),
            proxy: proxy,
            readinessSession: readinessSession,
            reportContext: reportContext)
    }

    /// Safe to call when already stopped.
    private func stop(
        reason: SessionEndReason,
        preserving readinessToPreserve: JarvisReadiness.Session? = nil,
        preservingReferenceStart: UUID? = nil
    ) {
        pendingStartRevision &+= 1
        if pendingReferenceAdmission?.startID != preservingReferenceStart { cancelPendingReferenceAdmission() }
        pendingStartTask?.cancel()
        pendingStartTask = nil
        // A blocker reported before any allocation stays visible until the next explicit Start, and
        // a replacement Start keeps the readiness attempt it just began.
        let preservesStartupBlock = !composition.hasAllocatedPipeline
            && reason != .applicationQuit
            && readiness.status.isBlocked
        composition.stop(reason: reason)
        showActiveBrainTarget(nil)
        if !preservesStartupBlock,
           let readinessSession = readiness.activeSession,
           readinessSession != readinessToPreserve {
            composition.applyReadinessEffects(readiness.stop(session: readinessSession))
        }
    }

    // MARK: - BrainCompositionHost

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
        showActiveBrainTarget(target)
    }

    private func showActiveBrainTarget(_ target: BrainTarget?) {
        brainSection?.setActiveTarget(target)
        settingsHub?.setActiveTarget(target)
    }

    private func renderReadinessStatus(_ status: JarvisReadiness.Status) {
        menuBar?.setStatus(status)
        activityViewer?.readinessDidChange(status)
    }

    private func cancelPendingReferenceAdmission() {
        guard let pending = pendingReferenceAdmission else { return }
        pendingReferenceAdmission = nil
        pending.cancel()
    }

    private func cancelPendingStart(using provider: BrainProvider) {
        guard pendingStartTask != nil,
              brain.preferences.route.targets.contains(where: { $0.provider == provider }) else {
            return
        }
        pendingStartRevision &+= 1
        cancelPendingReferenceAdmission()
        pendingStartTask?.cancel()
        pendingStartTask = nil
        if let session = readiness.activeSession {
            cancelReadinessAttempt(session)
        }
    }

    private func cancelReadinessAttempt(_ session: JarvisReadiness.Session) {
        guard readiness.activeSession == session else { return }
        composition.applyReadinessEffects(readiness.stop(session: session))
    }

}

private extension JarvisReadiness.Status {
    var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }
}
