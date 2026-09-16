import Foundation
import JarvisBrainProviders
import JarvisCore
import JarvisOverlay

/// Owns one coaching session's runtime, from an accepted Start to coaching ready and back to Stop.
///
/// The caller validates a Start (permissions, credentials, provider preflight) and hands the frozen
/// result to `start`. Everything after that lives here: the fresh transcript and session directory,
/// the capability set and route, the coach driver, both transcription endpoints, the audio source,
/// capture readiness, and the matching teardown. The audio source is the one piece a caller must
/// choose, through `makeAudioSource`. Screen capture and attempt auditing default to production and
/// may be replaced; every other object is built here the same way for every caller.
///
/// It presents nothing. Readiness status, shortcut registration, and the Settings and Activity
/// surfaces stay with the caller, fed by `onReadinessStatusChanged` and `onCoachingStateChanged`.
@MainActor
final class SessionComposition {
    /// What a Start froze for this session. Route topology, capability switches, and effort are read
    /// from `brain.preferences`, their one authority, while the session is installed.
    struct Inputs {
        let transcription: TranscriptionConfiguration
        /// Whichever credential the transcription provider owns; "" for Apple Speech.
        let transcriptionKey: String
        /// The brain's key stays OpenAI-only; "" when no OpenAI target needs it.
        let brainAPIKey: String
        let brainRoute: BrainRoute
        let appleSpeechLocale: Locale?
        let screen: ScreenCaptureSelection
        /// Configured prep sources, not a finished index: the index lands later and must not change
        /// what the session offers (#273).
        let prepSources: [PrepMaterialSource]
        let explanationsEnabled: Bool
        let codeEnabled: Bool
    }

    /// Every readiness status the session's observations produce, for the caller to render.
    var onReadinessStatusChanged: ((JarvisReadiness.Status) -> Void)?
    /// Whether coaching runs may have changed: a session went live, stopped, or finished draining.
    var onCoachingStateChanged: (() -> Void)?

    private let clock = SystemClock()
    private let config = Config.default
    private let networkDiagnostics = NetworkPathDiagnostics()
    private let brain: BrainComposition
    private let artifacts: SessionArtifacts
    private let overlayCaption: OverlayCaptionPanel   // transient on-screen tip
    private let overlayBox: OverlayBoxPanel            // persistent, movable history of every spoken response
    private let readiness: JarvisReadiness
    private let errorReporter: ErrorReporter
    private let makeAttemptAuditing: (FileSessionAudit) -> any CoachingAttemptAuditing
    private let makeScreenCapture: (URL) -> any ScreenCapturing
    private let makeAudioSource: MakeAudioSource

    /// Recreated on every `start`: the transcript must live and die with the driver/transcriber
    /// pair built there — they carry its [mm:ss] clock base and the driver's sent-index into it.
    private var transcript = RollingTranscript()
    /// Two provider sessions feeding one shared transcript: mic → `.me`, system audio → `.them`.
    private var transcriber: (any TranscriptionSession)?       // "me" (mic)
    private var themTranscriber: (any TranscriptionSession)?   // "them" (system audio)
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
    /// The session's producer of both speech streams, built by `makeAudioSource`.
    private var audioSource: (any AudioSource)?
    /// In-flight coaching turns, so Stop can cancel one mid-brain-call (otherwise it could speak
    /// after the user pressed Stop).
    private var turns: TurnTaskBox?
    /// The running session's event loop. Stored so Brain Settings can replace only its model clients
    /// without restarting transcription or discarding the session's transcript/history.
    private(set) var coachDriver: CoachDriver?
    /// Reads prep-material files and can shell out to `textutil`; cancelled on Stop like compaction
    /// is, so it never outlives the session it was built for.
    private var prepMaterialIndexTask: Task<Void, Never>?
    /// Fires an on-demand request for the running session. Non-nil only while running — set in
    /// `start`, cleared in `stop`. Captures the Sendable driver + turn box, like the transcriber
    /// callbacks do.
    private var requestManualHint: ((CoachingShortcut) -> Void)?
    /// Only cancelled coaching work extends the global ghost lifecycle. Audit persistence is scoped
    /// to its own session: Activity can use closed history while an unrelated audit drains.
    private var pendingTurnDrainIDs: Set<UUID> = []
    private var sessionExplanationsEnabled = false
    private var sessionCodeEnabled = false
    /// Monotonic revision stamped on each control-plane snapshot. Bumped at Start and whenever an
    /// explicit Settings edit installs a fresh plan; never by runtime health.
    private var planRevision: UInt = 0

    init(
        brain: BrainComposition,
        artifacts: SessionArtifacts,
        overlayCaption: OverlayCaptionPanel,
        overlayBox: OverlayBoxPanel,
        readiness: JarvisReadiness,
        errorReporter: ErrorReporter,
        // The port a session's coach records attempts through, built from the session's evidence
        // handle once Start has created it. Production records straight into that handle; a caller
        // that must watch attempts start and finish wraps it.
        makeAttemptAuditing: @escaping (FileSessionAudit) -> any CoachingAttemptAuditing = { $0 },
        // The session's screen capture, built with the session directory its transient shots use.
        // Production shoots the front window; a caller that must control what is on screen injects it.
        makeScreenCapture: @escaping (URL) -> any ScreenCapturing = {
            WindowScopedScreenCapture(captureDirectory: $0)
        },
        makeAudioSource: @escaping MakeAudioSource
    ) {
        self.brain = brain
        self.artifacts = artifacts
        self.overlayCaption = overlayCaption
        self.overlayBox = overlayBox
        self.readiness = readiness
        self.errorReporter = errorReporter
        self.makeAttemptAuditing = makeAttemptAuditing
        self.makeScreenCapture = makeScreenCapture
        self.makeAudioSource = makeAudioSource
        networkDiagnostics.start()
    }

    /// Whether transcription endpoints are allocated, live or still proving startup.
    var hasAllocatedPipeline: Bool { transcriber != nil || themTranscriber != nil }
    var isTranscriptionLive: Bool { transcriber != nil }
    /// Whether a session accepts shortcut requests.
    var isLive: Bool { requestManualHint != nil }
    /// Coaching is running, or a cancelled turn is still draining.
    var isCoachingRunning: Bool { transcriber != nil || !pendingTurnDrainIDs.isEmpty }

    func allows(_ shortcut: CoachingShortcut) -> Bool {
        switch shortcut {
        case .hint: true
        case .explainMore: sessionExplanationsEnabled
        case .showCode: sessionCodeEnabled
        }
    }

    /// Screenshot and ask for a guaranteed response, routed through the same turn box as audio
    /// triggers (so Stop cancels it and rapid presses coalesce). Ignored when no session runs.
    func requestShortcut(_ shortcut: CoachingShortcut) {
        requestManualHint?(shortcut)
    }

    /// Install a prepared session. The caller has already stopped any previous one. Returns false
    /// when the audio source cannot start, after reporting that through the error reporter with
    /// `reportContext`.
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
        // A fresh transcript for the fresh pipeline. Reusing the old one would re-send a dead run's
        // lines as "new since last turn" — their [mm:ss] stamps minted against the previous
        // transcriber's clock — and anchor silence math to old speech.
        transcript = RollingTranscript()
        let audit = artifacts.beginNewSession()  // rotate to a fresh session dir + activity/debug log
        let attemptAuditing = makeAttemptAuditing(audit)
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
        case .gemini:
            jlog("Jarvis transcription: provider=Gemini")
        }

        // Each target's coach and summarizer share the session traffic log. Every fresh attempt is a
        // distinct audit-visible request; no transport wrapper replays a failed request.
        let sessionDirectory = artifacts.currentSessionDir!
        // Fixed for the whole session.
        sessionCodeEnabled = inputs.codeEnabled
        overlayBox.setCodeEnabled(inputs.codeEnabled)
        sessionExplanationsEnabled = inputs.explanationsEnabled
        // One capability set for the session, handed to the driver that sends it. Prep material
        // counts as configured sources, not a finished index: the index lands later and must not
        // change what the session offers (#273).
        let prepMaterialSources = inputs.prepSources
        let bundledSkills = SkillCatalog.bundled()
        let capabilities = CoachCapabilities.compose(
            disabledTools: brain.preferences.disabledTools,
            disabledSkills: brain.preferences.disabledSkills,
            prepSourcesConfigured: !prepMaterialSources.isEmpty,
            skills: bundledSkills)
        // The one place a switched-off capability is visible: Activity never mentions what was not
        // offered. Read from the persisted names, so a name that matched nothing is reported as
        // nothing and a loader — which is synthesized, not switchable — is never named here.
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
            + capabilities.hotTools.map(\.name).joined(separator: ",")
            + " deferred=" + (capabilities.catalogNames.isEmpty
                ? "(none)" : capabilities.catalogNames.joined(separator: ","))
            + " skills=" + (capabilities.skills.isEmpty
                ? "(none)" : capabilities.skills.map(\.name).joined(separator: ","))
            + " switched-off=" + (honoredDisabled.isEmpty
                ? "(none)" : honoredDisabled.joined(separator: ",")))
        let configuredRoute = brain.makeConfiguredRoute(
            inputs.brainRoute,
            proxy: proxy,
            apiKey: inputs.brainAPIKey,
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
            screen: makeScreenCapture(sessionDirectory),
            overlay: overlaySink,
            clock: clock,
            sessionStart: conversationStart,
            coachingAttempts: attemptAuditing,
            plan: freshSessionPlan(screen: inputs.screen),
            activity: artifacts.sessionAudit,
            capabilities: capabilities)

        // Building the index reads files and can shell out to `textutil`, so it runs off the Start
        // path entirely rather than delaying it — a search that fires before this lands finds no
        // index for that one attempt. The tool itself was catalogued from Start, with the rest of
        // the session's fixed set. Tracked and cancelled in `stop()` for the same reason compaction
        // is: an untracked task would keep reading files and spawning textutil subprocesses after
        // the session it belongs to has already torn down. Skipped entirely when the session does
        // not offer the search, so switching the capability off also stops its file work rather
        // than building a port nothing can reach.
        if capabilities.tool(named: searchPrepNotesTool.name) != nil {
            prepMaterialIndexTask = Task.detached(priority: .utility) { [weak driver] in
                let index = await PrepMaterialIndexBuilder.build(from: prepMaterialSources)
                guard !Task.isCancelled else { return }
                driver?.installPrepMaterial(index)
            }
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

        // The audio source feeds the mic stream to the "me" socket and the system stream to the
        // "them" socket. If it can't be built, the whole capture is gone, so treat it as a full
        // (mic-side) terminal failure.
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
        // Like the transcriber callbacks above, bind the failure to the source that emitted it. A
        // final retry from an old source may arrive after Stop → Start; it must not tear down the
        // replacement session through ErrorReporter's global `onFatal`.
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
        // Arm the shortcuts for this session: capture the screen and ask for a guaranteed response,
        // routed through the same turn box as audio triggers (so Stop cancels it and rapid presses
        // coalesce).
        self.requestManualHint = { shortcut in
            turns.run { await driver.handleTrigger(shortcut.triggerReason) }
        }
        transcriber.connect()
        themTranscriber.connect()
        if let reason = source.start() {
            observeReadiness(.capture(.stopped), for: readinessSession)
            errorReporter.reportImmediately(
                .captureFailed(failure: Self.captureFailure(reason)), context: reportContext)
            return false
        }
        // Capture setup is synchronous and can legitimately take longer than the first-frame
        // deadline. Arm that deadline only after the source starts; callbacks were installed
        // above, so any frame already queued on the main actor is still observed by this monitor.
        startCaptureReadiness(readinessSession: readinessSession)
        sessionIsLive = true
        // Show the (already cleared) history box, from the one place that declares the session live —
        // every earlier `return false` leaves the desktop untouched.
        overlayBox.setSessionLive(true)
        jlog("Jarvis: coaching starting — verifying transcription endpoints.")
        jlog("Jarvis network path at start: \(networkDiagnostics.currentSummary)")
        onCoachingStateChanged?()   // the live session is no longer evaluable
        return true
    }

    /// Stop and tear down the audio source and BOTH transcription endpoints (mic/"me" and
    /// system-audio/"them"). Safe to call when already stopped. The source and both transcribers must
    /// go: otherwise a turn-end trigger from a still-live socket could drive a coaching turn on a
    /// torn-down driver — the exact "speak after Stop" failure the turns box exists to prevent — and
    /// a subsequent Start would leak the orphaned endpoints.
    ///
    /// Returns the background drain that seals this session's evidence, for a caller that must wait
    /// for `audit-health.json`; nil when there was nothing to drain.
    @discardableResult
    func stop(reason: SessionEndReason) -> Task<Void, Never>? {
        prepMaterialIndexTask?.cancel()
        prepMaterialIndexTask = nil
        let hadAllocatedPipeline = hasAllocatedPipeline
        let endedLiveSession = sessionIsLive
        sessionIsLive = false
        overlayBox.setSessionLive(false)     // the history box goes away with the session
        requestManualHint = nil              // shortcuts stop reaching a session
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
        // Mark both delivery endpoints stopped before draining the source. It hands chunks off
        // asynchronously, so callbacks already queued during teardown must see the transcribers'
        // stopped guards and become no-ops.
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
            // `sessionAudit` was already cleared above; record against the handle teardown holds so
            // the marker still reaches this session's evidence rather than the next one's.
            audit?.record(.sessionEnded(reason: reason))
        }
        // Activity is no longer a privileged failure domain: its rows ride the one bounded evidence
        // stack, so Stop drains this session's producers and evidence in the background and a
        // replacement Start stays instant. Quit seals best-effort and returns immediately —
        // evidence never owns app termination, so a last row may be lost and the session is then
        // honestly marked partial.
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
                // Closing the handle is the barrier now: it waits for every accepted row, Activity
                // included, so a just-recorded outcome cannot race the evaluator.
                _ = await audit?.close()
                if let auditDirectory { self?.artifacts.endClosing(auditDirectory) }
                self?.onCoachingStateChanged?()
            }
        }
        onCoachingStateChanged?()
        return drain
    }

    /// Keep a healthy live conversation intact when the credential file changes. Existing Realtime
    /// sockets are already authenticated; retain them and use the new key only if either socket later
    /// reconnects. The transcription half is session runtime and stays here; the brain half is
    /// composition's, and it installs fresh OpenAI target clients between coaching attempts without
    /// replacing subscription clients, changing route policy, or restarting transcription.
    ///
    /// Guarded by credential: a saved OpenAI key must never reach a Gemini-backed session (or vice
    /// versa). Each session applies only the credential it authenticates with and ignores the rest,
    /// so this passes the credential along rather than deciding on their behalf.
    func applySavedAPIKey(_ key: String, for credential: Credential) {
        guard let transcriber else { return }
        transcriber.updateAPIKey(key, for: credential)
        themTranscriber?.updateAPIKey(key, for: credential)
        if credential == .openAIAPIKey { brain.applySavedAPIKey(key) }
    }

    /// An explicit Settings edit takes effect at the next attempt. A turn already running keeps the
    /// revision it snapshotted, and nothing here rewrites a persisted preference.
    func updateScreenSelection(_ selection: ScreenCaptureSelection) {
        coachDriver?.updatePlan(freshSessionPlan(screen: selection))
    }

    func brainRecoveryDidChange(_ provider: BrainProvider?) {
        guard let readinessSession = readiness.activeSession else { return }
        observeReadiness(.brainRecovery(provider), for: readinessSession)
    }

    func brainCycleDidFail(_ provider: BrainProvider) {
        guard let readinessSession = readiness.activeSession else { return }
        let firstFailure = !readiness.hasFailedCoachingCycle
        observeReadiness(.brainCycleFailed(provider), for: readinessSession)
        guard firstFailure else { return }
        overlayCaption.showError("Coaching failed. I'm still listening.")
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

    /// The one funnel for readiness effects, whoever observed them: status goes to the caller to
    /// render, and the readiness milestone is logged here so every caller writes the same line.
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

    /// Wrap a capture cause in the one failure record Activity and the session lifecycle read. The
    /// capture is local, so there is no provider identity to carry: the sentence the capture layer
    /// already wrote is the whole evidence.
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

    /// Keep endpoint connection bookkeeping focused on seeding `CaptureReadinessMonitor`; Core owns
    /// every cross-subsystem status decision and both UI surfaces consume that result.
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

    /// Begin capture-frame readiness tracking for the session being installed. The 1s poll owns the
    /// initial first-frame deadline and the sustained-stall deadline after frame flow begins;
    /// observations arrive through `handleCaptureHeartbeat`.
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

    /// Fold one capture heartbeat into the focused monitor, then publish only its typed output to
    /// the overall composition reducer. This is the critical branch: everything here is in-memory
    /// policy over the heartbeat value, with no read of the evidence queue or a persisted file.
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

    /// Turn readiness consequences into lifecycle effects. A microphone capture failure is terminal; a
    /// system capture failure degrades to microphone-only. Fixed copy goes to Activity; the cause and
    /// counters stay in `jarvis-debug.log`.
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

    /// Freeze the control plane as the next revision.
    ///
    /// This is the only place preferences reach a coaching attempt. Everything a turn needs is
    /// resolved here, at Start or at an explicit Settings boundary, so no attempt reads storage
    /// (wiki/lean-coaching-core.md, Phase 4).
    private func freshSessionPlan(screen: ScreenCaptureSelection) -> SessionPlan {
        planRevision &+= 1
        return SessionPlan(revision: planRevision, screen: screen,
                           explanationsEnabled: sessionExplanationsEnabled, codeEnabled: sessionCodeEnabled)
    }
}
