import Foundation
import JarvisBrainProviders
import JarvisCore
import JarvisOverlay

@MainActor
final class SessionComposition {
    struct Inputs {
        let transcription: TranscriptionConfiguration
        /// "" when the transcription provider needs no credential (Apple Speech).
        let transcriptionKey: String
        /// Only keyed route targets appear; a subscription needs none.
        let brainKeys: [Credential: String]
        let brainRoute: BrainRoute
        let appleSpeechLocale: Locale?
        let screen: ScreenCaptureSelection
        /// Sources, not a finished index: the index lands later and must not change what the
        /// session offers.
        let prepSources: [PrepMaterialSource]
    }

    var onReadinessStatusChanged: ((JarvisReadiness.Status) -> Void)?
    var onCoachingStateChanged: (() -> Void)?

    private let clock = SystemClock()
    private let config = Config.default
    private let networkDiagnostics = NetworkPathDiagnostics()
    private let brain: BrainComposition
    private let artifacts: SessionArtifacts
    private let overlayBox: OverlayBoxPanel
    private let readiness: JarvisReadiness
    private let errorReporter: ErrorReporter
    private let makeAttemptAuditing: (FileSessionAudit) -> any CoachingAttemptAuditing
    private let makeScreenCapture: (URL) -> any ScreenCapturing
    private let makeAudioSource: MakeAudioSource

    private var transcript = RollingTranscript()
    private var transcriber: (any TranscriptionSession)?       // "me" (mic)
    private var themTranscriber: (any TranscriptionSession)?   // "them" (system audio)
    private var micConnectionState: TranscriptionConnectionState = .stopped
    private var systemConnectionState: TranscriptionConnectionState = .stopped
    private var reportedTranscriptionFailure = false
    private var captureReadiness: CaptureReadinessMonitor?
    private var captureReadinessStart: TimeInterval = 0
    private var captureReadinessTimer: Timer?
    /// Separate from `hasAllocatedPipeline`, so tearing down a Start that never went live doesn't
    /// record a session end.
    private var sessionIsLive = false
    private var audioSource: (any AudioSource)?
    private var turns: TurnTaskBox?
    private(set) var coachDriver: CoachDriver?
    private var prepMaterialIndexTask: Task<Void, Never>?
    private var requestManualHint: ((CoachingShortcut) -> Void)?
    /// Only cancelled coaching turns hold the ghost lifecycle open; an audit drain alone doesn't.
    private var pendingTurnDrainIDs: Set<UUID> = []
    /// Bumped only by Start and explicit Settings edits, never by runtime health.
    private var planRevision: UInt = 0

    init(
        brain: BrainComposition,
        artifacts: SessionArtifacts,
        overlayBox: OverlayBoxPanel,
        readiness: JarvisReadiness,
        errorReporter: ErrorReporter,
        makeAttemptAuditing: @escaping (FileSessionAudit) -> any CoachingAttemptAuditing = { $0 },
        makeScreenCapture: @escaping (URL) -> any ScreenCapturing = {
            WindowScopedScreenCapture(captureDirectory: $0)
        },
        makeAudioSource: @escaping MakeAudioSource
    ) {
        self.brain = brain
        self.artifacts = artifacts
        self.overlayBox = overlayBox
        self.readiness = readiness
        self.errorReporter = errorReporter
        self.makeAttemptAuditing = makeAttemptAuditing
        self.makeScreenCapture = makeScreenCapture
        self.makeAudioSource = makeAudioSource
        networkDiagnostics.start()
    }

    var hasAllocatedPipeline: Bool { transcriber != nil || themTranscriber != nil }
    var isTranscriptionLive: Bool { transcriber != nil }
    var isLive: Bool { requestManualHint != nil }
    var isCoachingRunning: Bool { transcriber != nil || !pendingTurnDrainIDs.isEmpty }

    /// Ignored when no session is live.
    func requestShortcut(_ shortcut: CoachingShortcut) {
        requestManualHint?(shortcut)
    }

    /// The caller must already have stopped any previous session. Returns false, after reporting
    /// with `reportContext`, when the audio source can't start.
    func start(
        _ inputs: Inputs,
        proxy: LocalProxySupervisor.Readiness?,
        readinessSession: JarvisReadiness.Session,
        reportContext: UserFacingError.PresentationContext
    ) -> Bool {
        let transcriptionConfiguration = inputs.transcription
        let transcriptionKey = inputs.transcriptionKey
        let appleSpeechLocale = inputs.appleSpeechLocale
        reportedTranscriptionFailure = false
        // Fresh per pipeline: a reused transcript would re-send a dead run's lines, stamped on the
        // old clock, and anchor silence math to old speech.
        transcript = RollingTranscript()
        let audit = artifacts.beginNewSession()
        let attemptAuditing = makeAttemptAuditing(audit)
        overlayBox.clear()
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

        let sessionDirectory = artifacts.currentSessionDir!
        let prepMaterialSources = inputs.prepSources
        let bundledSkills = SkillCatalog.bundled()
        let capabilities = CoachCapabilities.compose(
            disabledTools: brain.preferences.disabledTools,
            disabledSkills: brain.preferences.disabledSkills,
            prepSourcesConfigured: !prepMaterialSources.isEmpty,
            skills: bundledSkills)
        // This log line is the only place switched-off capabilities appear. It lists only saved
        // names that match a real, switchable capability.
        let everything = CoachCapabilities.compose(
            disabledTools: [], prepSourcesConfigured: !prepMaterialSources.isEmpty,
            skills: bundledSkills)
        let honoredDisabled = brain.preferences.disabledTools
            .subtracting(CoachCapabilities.fixedToolNames)
            .filter { everything.tool(named: $0) != nil }
            .sorted()
            + brain.preferences.disabledSkills
            .filter { everything.skill(named: $0) != nil }
            .sorted()
        jlog("Jarvis coach capabilities: hot="
            + capabilities.tools.map(\.name).joined(separator: ",")
            + " deferred=" + (capabilities.catalogNames.isEmpty
                ? "(none)" : capabilities.catalogNames.joined(separator: ","))
            + " skills=" + (capabilities.skills.isEmpty
                ? "(none)" : capabilities.skills.map(\.name).joined(separator: ","))
            + " switched-off=" + (honoredDisabled.isEmpty
                ? "(none)" : honoredDisabled.joined(separator: ",")))
        let configuredRoute = brain.makeConfiguredRoute(
            inputs.brainRoute,
            proxy: proxy,
            keys: inputs.brainKeys,
            effort: brain.preferences.effort,
            sessionDirectory: sessionDirectory)
        observeReadiness(.brainPreparation(.ready), for: readinessSession)
        // One shared origin keeps mic and system timestamps comparable.
        let conversationStart = clock.now()
        let driver = CoachDriver(
            config: config,
            transcript: transcript,
            route: configuredRoute,
            screen: makeScreenCapture(sessionDirectory),
            overlay: overlayBox,
            clock: clock,
            sessionStart: conversationStart,
            coachingAttempts: attemptAuditing,
            plan: freshSessionPlan(screen: inputs.screen),
            activity: artifacts.sessionAudit,
            capabilities: capabilities)

        // Off the Start path: it reads files and may spawn `textutil`, and a search before it lands
        // just finds no index. `stop()` cancels it so it can't outlive the session.
        if capabilities.tool(named: searchPrepNotesTool.name) != nil {
            prepMaterialIndexTask = Task.detached(priority: .utility) { [weak driver] in
                let index = await PrepMaterialIndexBuilder.build(from: prepMaterialSources)
                guard !Task.isCancelled else { return }
                driver?.installPrepMaterial(index)
            }
        }

        // CoachDriver is @unchecked Sendable; capture it (not @MainActor self) in the callbacks.
        // CoachDriver coalesces triggers, so a new one doesn't cancel the running turn.
        let turns = TurnTaskBox()
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

        // No onSilence here: the "are you stuck?" check is about the user, so only the mic drives
        // it.
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
        // The identity checks keep a callback queued across Stop and Start away from the
        // replacement session.
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
                // Key on the failure, not the provider: a rejected key or denied region on this
                // side threatens the mic side too.
                if failure.endsEverySession {
                    self.reportTranscriptionFailure(failure)
                    return
                }
                themTranscriber.stop()
                self.themTranscriber = nil
                // The async `.stopped` callback is ignored once this is nil, so record the state
                // here.
                self.systemConnectionState = .failed
                // Stop expecting system frames so a capture first-frame/stall timeout can't also fire.
                self.captureReadiness?.systemBecameUnavailable()
                self.observeEndpointAndCaptureReadiness(
                    stream: .system, state: .failed, for: readinessSession)
                self.artifacts.sessionAudit?.record(.systemAudioStopped(failure: failure))
                self.errorReporter.reportImmediately(.systemAudioStopped, context: .runtime)
            }
        }

        let localTurnDetectionSilenceDuration: TimeInterval? =
            transcriptionConfiguration.turnDetectionStrategy == .clientCommit
            ? TimeInterval(config.localEndpointSilenceDurationMs) / 1_000
            : nil
        let source = makeAudioSource(
            transcriptionConfiguration.provider.audioFormat,
            localTurnDetectionSilenceDuration,
            AudioDelivery(
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
                onMicSpeechEvent: { [weak transcriber] event, sequence in
                    transcriber?.recordLocalSpeechEvent(
                        event, throughSequenceNumber: sequence)
                },
                onSystemSpeechEvent: { [weak themTranscriber] event, sequence in
                    themTranscriber?.recordLocalSpeechEvent(
                        event, throughSequenceNumber: sequence)
                }))
        source.onUnavailable = { [weak self, weak source] reason in
            guard let source else { return }
            Task { @MainActor [weak self] in
                guard let self, self.audioSource === source else { return }
                self.observeReadiness(.capture(.stopped), for: readinessSession)
                self.errorReporter.reportImmediately(
                    .captureStopped(failure: Self.captureFailure(reason)), context: .runtime)
            }
        }
        source.onRecoveryStateChange = { [weak self, weak source] inProgress in
            guard let source else { return }
            Task { @MainActor [weak self] in
                guard let self, self.audioSource === source,
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
        self.audioSource = source
        self.turns = turns
        self.coachDriver = driver
        brain.sessionWillStart()
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
        self.requestManualHint = { shortcut in
            guard let reason = shortcut.triggerReason else { return }
            turns.run { await driver.handleTrigger(reason) }
        }
        transcriber.connect()
        themTranscriber.connect()
        if let reason = source.start() {
            observeReadiness(.capture(.stopped), for: readinessSession)
            errorReporter.reportImmediately(
                .captureFailed(failure: Self.captureFailure(reason)), context: reportContext)
            return false
        }
        // Armed only after the synchronous source start, which can outlast the first-frame
        // deadline. Frames queued meanwhile still reach the monitor.
        startCaptureReadiness(readinessSession: readinessSession)
        sessionIsLive = true
        // Only after every early return, so a failed Start leaves the desktop untouched.
        overlayBox.setSessionLive(true)
        jlog("Jarvis: coaching starting — verifying transcription endpoints.")
        jlog("Jarvis network path at start: \(networkDiagnostics.currentSummary)")
        onCoachingStateChanged?()
        return true
    }

    /// Safe to call when already stopped. Returns the drain that seals this session's evidence
    /// (`audit-health.json`), or nil when there was nothing to drain.
    @discardableResult
    func stop(reason: SessionEndReason) -> Task<Void, Never>? {
        prepMaterialIndexTask?.cancel()
        prepMaterialIndexTask = nil
        let hadAllocatedPipeline = hasAllocatedPipeline
        let endedLiveSession = sessionIsLive
        sessionIsLive = false
        overlayBox.setSessionLive(false)
        requestManualHint = nil
        // Take the handle before a quick Start can install another; cancelled turns still write to
        // the old session.
        let (audit, auditDirectory) = artifacts.takeCurrentSession()
        let cancelled = turns?.cancelAll() ?? []; turns = nil
        // `turns` doesn't own compaction. Cancel and drain it, or a summary keeps billing after
        // Stop and can still be writing when the audit seals.
        let compaction = coachDriver?.cancelBackgroundWork()
        coachDriver = nil
        brain.sessionDidStop()
        // Stop the transcribers before the source, so its queued async chunks hit their stopped
        // guards.
        transcriber?.stop()
        themTranscriber?.stop()
        audioSource?.stop(); audioSource = nil
        transcriber = nil
        themTranscriber = nil
        stopCaptureReadiness()
        micConnectionState = .stopped
        systemConnectionState = .stopped
        if hadAllocatedPipeline {
            jlog("Jarvis: stopped.")
        }
        if endedLiveSession {
            // `artifacts.sessionAudit` is already cleared, so record on the taken handle.
            audit?.record(.sessionEnded(reason: reason))
        }
        // Quit abandons instead of draining: evidence never delays termination, so a last row may
        // be lost and the session marked partial.
        var drain: Task<Void, Never>?
        if reason == .applicationQuit {
            audit?.abandon()
        } else if audit != nil || !cancelled.isEmpty || compaction != nil {
            let drainID = UUID()
            if !cancelled.isEmpty { pendingTurnDrainIDs.insert(drainID) }
            if let auditDirectory { artifacts.beginClosing(auditDirectory) }
            drain = Task { @MainActor [weak self] in
                for task in cancelled { await task.value }
                await compaction?.value
                self?.pendingTurnDrainIDs.remove(drainID)
                self?.onCoachingStateChanged?()
                // close() waits for every accepted row, so a just-recorded outcome can't race the
                // evaluator.
                _ = await audit?.close()
                if let auditDirectory { self?.artifacts.endClosing(auditDirectory) }
                self?.onCoachingStateChanged?()
            }
        }
        onCoachingStateChanged?()
        return drain
    }

    /// Live sockets stay authenticated and use the new key only on reconnect. Each session applies
    /// only the credential it authenticates with, so an OpenAI key never reaches a Gemini session.
    func applySavedAPIKey(_ key: String, for credential: Credential) {
        guard let transcriber else { return }
        transcriber.updateAPIKey(key, for: credential)
        themTranscriber?.updateAPIKey(key, for: credential)
        brain.applySavedKey(key, for: credential)
    }

    /// Takes effect at the next attempt; a running turn keeps its snapshot.
    func updateScreenSelection(_ selection: ScreenCaptureSelection) {
        coachDriver?.updatePlan(freshSessionPlan(screen: selection))
    }

    func brainRecoveryDidChange(_ provider: BrainProvider?) {
        guard let readinessSession = readiness.activeSession else { return }
        observeReadiness(.brainRecovery(provider), for: readinessSession)
    }

    func brainCycleDidFail(_ provider: BrainProvider) {
        guard let readinessSession = readiness.activeSession else { return }
        observeReadiness(.brainCycleFailed(provider), for: readinessSession)
    }

    // MARK: - Readiness

    func observeReadiness(
        _ observation: JarvisReadiness.Observation,
        for session: JarvisReadiness.Session
    ) {
        applyReadinessEffects(readiness.observe(observation, for: session))
    }

    func observeReadiness(
        _ observations: [JarvisReadiness.Observation],
        for session: JarvisReadiness.Session
    ) {
        applyReadinessEffects(readiness.observe(observations, for: session))
    }

    func applyReadinessEffects(_ effects: [JarvisReadiness.Effect]) {
        for effect in effects {
            switch effect {
            case .statusChanged(let status):
                onReadinessStatusChanged?(status)
            case .readinessEstablished(.full):
                jlog("Jarvis: coaching ready (mic + system audio).")
            case .readinessEstablished(.microphoneOnly):
                jlog("Jarvis: coaching ready (microphone only).")
            }
        }
    }

    /// Capture is local, so the failure carries no provider identity.
    private static func captureFailure(_ reason: String) -> ProviderFailure {
        ProviderFailure(
            source: .capture, stage: .local, category: .unavailable, disposition: .permanent,
            identity: .init(), message: reason)
    }

    /// Either side may fail first; report one reason and tear down once.
    private func reportTranscriptionFailure(_ failure: ProviderFailure) {
        guard !reportedTranscriptionFailure, transcriber != nil || themTranscriber != nil else { return }
        reportedTranscriptionFailure = true
        // Synchronous, so Stop and Start can't slip in after the caller's identity check.
        errorReporter.reportImmediately(
            .transcriptionStopped(failure: failure), context: .runtime)
    }

    private func handleTranscriptionConnectionState(
        _ state: TranscriptionConnectionState,
        for stream: CaptureReadinessMonitor.Stream,
        readinessSession: JarvisReadiness.Session
    ) {
        guard readiness.activeSession == readinessSession else { return }
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

    /// The 1 s poll enforces the first-frame and sustained-stall deadlines.
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
                      self.readiness.activeSession == readinessSession else { return }
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

    /// Hot path: stays in memory, with no read of the evidence queue or a persisted file.
    private func handleCaptureHeartbeat(
        _ heartbeat: CaptureHeartbeat,
        for stream: CaptureReadinessMonitor.Stream,
        readinessSession: JarvisReadiness.Session
    ) {
        guard readiness.activeSession == readinessSession, let captureReadiness else { return }
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

    private func applyCaptureReadinessEffects(
        _ effects: [CaptureReadinessMonitor.Effect],
        readinessSession: JarvisReadiness.Session
    ) {
        guard readiness.activeSession == readinessSession else { return }
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

    /// The only path from preferences to an attempt, so no attempt reads storage.
    private func freshSessionPlan(screen: ScreenCaptureSelection) -> SessionPlan {
        planRevision &+= 1
        return SessionPlan(revision: planRevision, screen: screen)
    }
}
