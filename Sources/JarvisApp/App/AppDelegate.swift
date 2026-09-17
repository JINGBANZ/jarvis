import AppKit
import JarvisBrainProviders
import JarvisCore
import JarvisEvaluation
import JarvisOverlay

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, BrainCompositionHost {
    private let secretFile = FileSecretStore()
    private lazy var secrets = ChainedSecretStore([secretFile, EnvSecretStore()])
    private let errorReporter = ErrorReporter()

    private var overlayCaption: OverlayCaptionPanel!
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
    private let prepMaterialPreferences = PrepMaterialPreferences()
    private let permissionPreferences = PermissionPreferences()
    private var permissionGate: PermissionGate!
    private var didStartApp = false
    private let hotkeyPreferences = CoachingShortcut.allCases.map { HotkeyPreferences(shortcut: $0) }
    private var activityViewer: ActivityViewer!
    private let readiness = JarvisReadiness()
    private var pendingStartTask: Task<Void, Never>?
    private var pendingStartRevision: UInt = 0
    private var hotkeys: HotkeyController?
    private let artifacts = SessionArtifacts()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // ghost-mode-allowed: launch configuration
        MainMenu.install()

        permissionGate = PermissionGate(preferences: permissionPreferences)
        permissionGate.onSatisfied = { [weak self] in self?.startApp() }
        // Async: proving the system-audio grant runs a tap, which must not block the main thread.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if await self.permissionGate.holdsEveryGrant() {
                self.startApp()
            } else {
                self.permissionGate.present()
            }
        }
    }

    private func startApp() {
        didStartApp = true
        let supervisor = LocalProxySupervisor(
            executable: LocalProxySupervisor.bundledExecutable(),
            home: secretFile.directoryURL.appendingPathComponent("proxy", isDirectory: true))
        proxySupervisor = supervisor
        brain = BrainComposition(secrets: secrets, host: self, supervisor: supervisor)
        if brain.preferences.route.targets.contains(where: { $0.provider.servedByLocalProxy }) {
            Task { await supervisor.ensureRunning() }
        }

        activityViewer = ActivityViewer(log: .shared,
                                        store: SessionStore(base: artifacts.logDirectory(), current: nil))
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
        activityViewer.makeEvaluator = { [weak self] session in
            guard let self else { return nil }
            return AgenticEvaluator(source: self.artifacts.evaluationSource(for: session))
        }

        overlayCaption = OverlayCaptionPanel()
        overlayCaption.setFontSize(appearance.captionFontSize)
        overlayCaption.setBackgroundOpacity(appearance.captionBackgroundOpacity)
        overlayCaption.setEnabled(appearance.captionEnabled)

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
        // Only arms the switch; the box appears on Start and hides on Stop.
        overlayBox.setEnabled(appearance.boxEnabled)

        composition = SessionComposition(
            brain: brain,
            artifacts: artifacts,
            overlayCaption: overlayCaption,
            overlayBox: overlayBox,
            readiness: readiness,
            errorReporter: errorReporter,
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

        // Built before Settings, whose hotkey closures apply through it. The optional shortcuts
        // answer into the detail box, so they register only while the box is enabled.
        hotkeys = HotkeyController(preferences: hotkeyPreferences.filter {
            $0.shortcut == .hint || appearance.boxEnabled
        })

        let signIns = SubscriptionSignIns(supervisor: supervisor)
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
            supervisor: supervisor,
            keyStore: secretFile,
            signIns: signIns,
            onKeySaved: { [weak self] credential, key in
                self?.composition.applySavedAPIKey(key, for: credential)
                // A saved key writes a file, not UserDefaults, so nothing else would re-judge the hub.
                self?.settingsHub.refresh(probe: false)
            })
        let hotkeySection = HotkeySection(
                preferences: hotkeyPreferences,
                boxEnabled: { [weak self] in self?.appearance.boxEnabled == true },
                hasActiveHotkey: { [weak self] shortcut in
                    guard let self else { return false }
                    // Deferred bindings have no live registration to warn about until Start.
                    return (self.composition.isLive && !self.composition.allows(shortcut))
                        || self.hotkeys?.registered[shortcut] != nil
                },
                applyCombination: { [weak self] shortcut, combination in
                    // Only a torn-down self reaches the fallback; report failure, not a rebind.
                    guard let self else { return .failed(status: -1) }
                    let outcome = self.hotkeys?.apply(combination, for: shortcut) ?? .failed(status: -1)
                    if (shortcut != .hint && !self.appearance.boxEnabled)
                        || (self.composition.isLive && !self.composition.allows(shortcut)) {
                        self.hotkeys?.unregister(shortcut) // Validate ownership, then release until Start.
                    }
                    return outcome
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
            OverlaySection(appearance: appearance, caption: overlayCaption, box: overlayBox,
                onBoxEnabledChanged: { [weak self] _ in
                    guard let self else { return }
                    self.refreshOptionalShortcut(.explainMore)
                    self.refreshOptionalShortcut(.showCode)
                    self.refreshOptionalShortcut(.previousDetail)
                    self.refreshOptionalShortcut(.nextDetail)
                }),
            connectionsSection,
            ToolsSection(brainPreferences: brain.preferences, prepPreferences: prepMaterialPreferences),
            SkillsSection(preferences: brain.preferences),
            hotkeySection,
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
                if shortcut.triggerReason != nil {
                    NSSound.beep() // ghost-mode-allowed: explicit user coaching hotkey while stopped
                }
                return
            }
            guard self.composition.allows(shortcut) else { return }
            switch shortcut {
            case .previousDetail: self.overlayBox.showPreviousDetail()
            case .nextDetail: self.overlayBox.showNextDetail()
            case .hint, .explainMore, .showCode: self.composition.requestShortcut(shortcut)
            }
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
        // Quitting from the permission gate: nothing exists to stop yet.
        guard didStartApp else { return .terminateNow }
        activityViewer?.cancelEvaluation()
        stop(reason: .applicationQuit)
        proxySupervisor?.terminateNow()
        return .terminateNow
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
        let detailEnabled = appearance.boxEnabled
        let brainKeys = brain.savedKeys(for: brainRoute)
        let transcriptionKey = transcriptionProvider.ownCredential
            .flatMap { secrets.apiKey(for: $0) } ?? ""
        let requiredCredentials = transcriptionProvider.requiredCredentials(for: brainRoute)
        let preparesAppleSpeech = transcriptionProvider == .appleSpeech
        // System audio is left to the probe below: requiring its last answer here would let one
        // failed probe refuse every later Start until relaunch.
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

            // Re-prove per session: a revoked grant's tap still delivers silent frames, and capture
            // health counts frames, not amplitude.
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
            // A key saved while Start was preparing makes the prepared keys stale.
            let brainKeysAreCurrent = self.brain.savedKeys(for: brainRoute) == brainKeys
            let transcriptionCredentialIsCurrent = transcriptionProvider.ownCredential.map {
                (self.secrets.apiKey(for: $0) ?? "") == transcriptionKey
            } ?? true
            guard brainKeysAreCurrent, transcriptionCredentialIsCurrent,
                  self.transcriptionPreferences.configuration == transcriptionConfiguration,
                  self.brain.preferences.route == brainRoute else {
                self.pendingStartTask = nil
                self.cancelReadinessAttempt(readinessSession)
                return
            }
            self.pendingStartTask = nil
            _ = self.installPreparedStart(
                brainKeys: brainKeys,
                transcriptionKey: transcriptionKey,
                brainRoute: brainRoute,
                detailEnabled: detailEnabled,
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
        errorReporter.reportImmediately(.permissionsMissing([.systemAudio]), context: context)
    }

    /// Refuses a route with no usable target before stopping the running pipeline.
    private func installPreparedStart(
        brainKeys: [Credential: String],
        transcriptionKey: String,
        brainRoute: BrainRoute,
        detailEnabled: Bool,
        transcriptionConfiguration: TranscriptionConfiguration,
        appleSpeechLocale: Locale?,
        proxy: LocalProxySupervisor.Readiness?,
        wasRunning: Bool,
        reportContext: UserFacingError.PresentationContext,
        readinessSession: JarvisReadiness.Session
    ) -> Bool {
        guard readiness.activeSession == readinessSession else { return false }
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
        // Follows the box setting this session is frozen with, not the live one.
        for shortcut in CoachingShortcut.allCases where shortcut != .hint {
            if detailEnabled,
               let preference = hotkeyPreferences.first(where: { $0.shortcut == shortcut }) {
                hotkeys?.apply(preference.combination, for: shortcut)
            } else {
                hotkeys?.unregister(shortcut)
            }
        }
        showActiveBrainTarget(
            brain.unavailability(for: brainRoute.primary, proxy: proxy) == nil ? brainRoute.primary : nil)
        return composition.start(
            SessionComposition.Inputs(
                transcription: transcriptionConfiguration,
                transcriptionKey: transcriptionKey,
                brainKeys: brainKeys,
                brainRoute: brainRoute,
                appleSpeechLocale: appleSpeechLocale,
                screen: screenPreferences.selection,
                prepSources: prepMaterialPreferences.sources,
                detailEnabled: detailEnabled),
            proxy: proxy,
            readinessSession: readinessSession,
            reportContext: reportContext)
    }

    /// Safe to call when already stopped.
    private func stop(
        reason: SessionEndReason,
        preserving readinessToPreserve: JarvisReadiness.Session? = nil
    ) {
        pendingStartRevision &+= 1
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

    private func cancelReadinessAttempt(_ session: JarvisReadiness.Session) {
        guard readiness.activeSession == session else { return }
        composition.applyReadinessEffects(readiness.stop(session: session))
    }

    private func refreshOptionalShortcut(_ shortcut: CoachingShortcut) {
        if appearance.boxEnabled, !composition.isLive || composition.allows(shortcut),
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
