import AppKit
import JarvisBrainProviders
import JarvisCore
import JarvisOverlay

/// Runs one live e2e scenario through the production session composition in a hidden process.
///
/// Everything a menu Start builds is built here by the same `SessionComposition`. The scenario
/// chooses only what a person would: the brain route and capability switches (written to a private
/// defaults suite, never the developer's own), the audio source (synthesized speech on both streams,
/// or the real capture device), and when a line is spoken, a shortcut pressed, a brain switched, or
/// the session stopped.
///
/// Steps wait on the app's own coaching-attempt records, never on timers, so chronology and
/// in-flight cases run against real state. A spoken step matches the next `turn_end` attempt and a
/// press matches its manual attempt; the automatic silence check can start attempts of its own in
/// between, so each match is written to `steps.jsonl` for the checker instead of being inferred from
/// order. The screen is the scenario's fixture image, handed to the composition's screen capture in
/// place of the Mac's front window, so a developer can keep using the Mac during a run.
@MainActor
final class LiveE2ERunner: BrainCompositionHost {
    enum Failure: Error, CustomStringConvertible {
        case credentialUnavailable
        case defaultsSuiteUnavailable
        case notReadyToStart(String)
        case brainUnavailable(BrainProvider)
        case startFailed
        case stubUnavailable
        case noFixtureAudio(Int)
        case unexpectedSessionEnd(String)
        case timedOut(String)
        case aborted

        var description: String {
            switch self {
            case .credentialUnavailable:
                "OpenAI API key unavailable in the owner-only key file or OPENAI_API_KEY"
            case .defaultsSuiteUnavailable: "Could not open the live e2e defaults suite"
            case .notReadyToStart(let blocker): "Start is blocked: \(blocker)"
            case .brainUnavailable(let provider): "\(provider.displayName) failed its Start preflight"
            case .startFailed: "The session composition could not start"
            case .stubUnavailable: "The scenario needs a stub Claude Code executable, and none was passed"
            case .noFixtureAudio(let step): "Step \(step) speaks, but this scenario has no fixture audio"
            case .unexpectedSessionEnd(let reason): "The session ended unexpectedly: \(reason)"
            case .timedOut(let what): "Timed out waiting for \(what)"
            case .aborted: "Live e2e scenario aborted"
            }
        }
    }

    private enum AttemptEvent {
        case started(id: Int, reason: TriggerReason)
        case finished(id: Int)
    }

    private struct SpokenClips {
        let line: [Int16]
        let overlap: [Int16]?
    }

    private static let defaultsSuite = "com.jarvis.coach.dev.live-e2e"
    /// Seven responses at the 15 s live-coaching timeout is 105 s of provider time alone.
    private static let attemptTimeout: TimeInterval = 240
    private static let stepTimeout: TimeInterval = 60
    private static let scenarioTimeout: TimeInterval = 20 * 60
    private static let settleDuration: Duration = .milliseconds(1_500)

    private let options: LiveE2EOptions
    private let secrets: any SecretStore
    private let readiness = JarvisReadiness()
    private let errorReporter = ErrorReporter()
    private let artifacts: SessionArtifacts
    private let speech: FixtureSpeech
    private let screen = FixtureScreenCapture()
    private var brain: BrainComposition!
    private var composition: SessionComposition!
    private var fixtureSource: FixtureAudioSource?
    private var detectedCLIs: [BrainProvider: DetectedAgentCLI] = [:]
    private var prepSources: [PrepMaterialSource] = []
    private var sessionEnd: SessionEndReason?
    private var expectsSessionEnd = false
    private var drain: Task<Void, Never>?
    private var attemptEvents: [AttemptEvent] = []
    /// Where in `attemptEvents` a line scheduled ahead of its own step was started, so that step
    /// matches only attempts after its speech began.
    private var earlyClipMarks: [Int: Int] = [:]
    private var stepAttemptLines: [String] = []
    private var currentStep: Int?
    private var runDeadline = Date.distantFuture

    init(options: LiveE2EOptions) {
        self.options = options
        // F02 points the file half of the store at a run-local directory holding an invalid key.
        secrets = ChainedSecretStore([
            FileSecretStore(directoryURL: options.secretsDirectory), EnvSecretStore(),
        ])
        artifacts = SessionArtifacts(
            baseDirectory: options.outputDirectory.appendingPathComponent("session", isDirectory: true))
        speech = FixtureSpeech(
            directory: options.outputDirectory.appendingPathComponent("fixtures", isDirectory: true))
    }

    /// Run the scenario, then leave `live-e2e-finished` only after the session's evidence is sealed,
    /// or `live-e2e-error.json` naming the step that failed.
    func run() async {
        runDeadline = Date().addingTimeInterval(Self.scenarioTimeout)
        do {
            try await runScenario()
            try removeGeneratedAudio()
            try TranscriptionBenchmarkFiles.createMarker(
                named: "live-e2e-finished", in: options.outputDirectory)
        } catch {
            jlog("Jarvis live e2e failed: \(error)")
            if let composition, sessionEnd == nil {
                drain = composition.stop(reason: .stoppedByUser)
            }
            await drain?.value
            var failure = String(describing: error)
            do {
                try removeGeneratedAudio()
            } catch {
                failure += "; removing synthesized speech also failed: \(error)"
            }
            writeFailure(failure)
        }
    }

    func removeGeneratedAudio() throws {
        try speech.removeDirectory()
    }

    // MARK: - Scenario

    private func runScenario() async throws {
        let scenario = try LiveE2EScenario.load(
            from: options.scenarioURL, fixturesDirectory: options.fixturesDirectory)
        try speech.prepareDirectory()
        let clips = try synthesizeLines(of: scenario)
        try removeGeneratedAudio()
        brain = BrainComposition(
            secrets: secrets, host: self, preferences: try makePreferences(for: scenario))
        detectedCLIs = try await detectCLIs(for: scenario)
        prepSources = scenario.prepNotes.map {
            [PrepMaterialSource(
                path: options.fixturesDirectory.appendingPathComponent($0).path,
                isDirectory: false)]
        } ?? []
        composition = makeComposition(audio: scenario.audio)

        let steps = scenario.steps
        var index = 0
        try await startSession(scenario)
        guard !expectsSessionEnd else { return }

        while index < steps.count {
            currentStep = index
            try checkAbort()
            switch steps[index] {
            case .screen(let fixture):
                screen.show(try Data(contentsOf: options.fixturesDirectory.appendingPathComponent(fixture)))
            case .press(let shortcut):
                let mark = attemptEvents.count
                composition.requestShortcut(shortcut)
                try await awaitAttempt(step: index, since: mark, onStart: nil) {
                    $0 == shortcut.triggerReason
                }
            case .say(let line, let overlap, _):
                guard fixtureSource != nil, let spoken = clips[index] else {
                    throw Failure.noFixtureAudio(index)
                }
                let mark: Int
                if let early = earlyClipMarks[index] {
                    mark = early
                } else {
                    mark = attemptEvents.count
                    play(spoken, line: line, overlap: overlap)
                }
                // A following line marked `whileAttemptRunning` starts as soon as this step's
                // attempt does, so it lands while that attempt is in flight.
                var onStart: (() -> Void)?
                let next = index + 1
                if next < steps.count, case .say(let nextLine, let nextOverlap, true) = steps[next],
                   let nextClips = clips[next] {
                    onStart = { [weak self] in
                        guard let self else { return }
                        self.earlyClipMarks[next] = self.attemptEvents.count
                        self.play(nextClips, line: nextLine, overlap: nextOverlap)
                    }
                }
                try await awaitAttempt(step: index, since: mark, onStart: onStart) {
                    $0 == .turnEnd
                }
            case .switchBrain(let provider):
                brain.preferences.route = BrainRoute(
                    primary: Self.defaultTarget(for: provider), fallbackTargets: [])
                // Applied the way a Settings topology edit is: on the next attempt, with the
                // session's transcript, history, and loaded capabilities intact.
                brain.applyBrainPreferencesToRunningSession(
                    detectedCLIs: detectedCLIs, update: .topologyEdit)
            case .restoreCLI:
                // The stub checks for this marker on every launch and hands over to the real CLI.
                try TranscriptionBenchmarkFiles.createMarker(
                    named: "claude-restored", in: options.outputDirectory)
            case .stop:
                drain = composition.stop(reason: .stoppedByUser)
                await drain?.value
            }
            index += 1
        }
    }

    private func startSession(_ scenario: LiveE2EScenario) async throws {
        let key = secrets.apiKey(for: .openAIAPIKey) ?? ""
        guard !key.isEmpty else { throw Failure.credentialUnavailable }
        let route = brain.preferences.route
        // The readiness requirements of a menu Start. Its system-audio tone probe is skipped: fixture
        // sources never open the tap, and the device scenario fails at the capture's own start when
        // that grant is gone.
        let begun = readiness.begin(configuration: JarvisReadiness.Configuration(
            requiredPermissions: PermissionGate.required.subtracting([.systemAudio]),
            requiredCredentials: TranscriptionProvider.openAI.requiredCredentials(for: route)))
        let readinessSession = begun.session
        composition.applyReadinessEffects(begun.effects)
        composition.observeReadiness(
            .permissions(granted: Permissions.grantedReadinessPermissions()), for: readinessSession)
        composition.observeReadiness(
            .credentials(available: Set(Credential.allCases.filter {
                secrets.apiKey(for: $0)?.isEmpty == false
            })),
            for: readinessSession)
        if case .blocked(let blocker) = readiness.status {
            throw Failure.notReadyToStart(String(describing: blocker))
        }
        let primary = route.primary.provider
        let preflight = brain.preflightBrainProvider(
            primary, detectedCLI: detectedCLIs[primary], context: .runtime,
            recordSettingsFailure: false)
        guard preflight.isReady else { throw Failure.brainUnavailable(primary) }
        if let cli = preflight.cli { detectedCLIs[primary] = cli }

        expectsSessionEnd = scenario.audio == .fixtureNoMicrophone
            || scenario.transcription.key == .invalid
        let inputs = SessionComposition.Inputs(
            transcription: TranscriptionConfiguration(
                provider: .openAI,
                openAIModel: scenario.transcription.model,
                openAIExpectedLanguages: [],
                appleSpeechLocaleIdentifier: Defaults.Transcription.appleSpeechLocaleIdentifier),
            transcriptionKey: key,
            brainAPIKey: key,
            brainRoute: route,
            appleSpeechLocale: nil,
            // The fixture capture shows the scenario's image whatever the selection names.
            screen: SessionPlan.default.screen,
            prepSources: prepSources,
            explanationsEnabled: Defaults.Explanations.enabled,
            codeEnabled: Defaults.Code.enabled)
        guard composition.start(
            inputs, detectedCLIs: detectedCLIs, readinessSession: readinessSession,
            reportContext: .runtime)
        else { throw Failure.startFailed }

        let limit = Date().addingTimeInterval(Self.stepTimeout)
        if expectsSessionEnd {
            try await wait(until: limit, for: "the session to end") { self.sessionEnd != nil }
            await drain?.value
        } else {
            let mode: JarvisReadiness.ReadyMode =
                scenario.audio == .fixtureNoSystem ? .microphoneOnly : .full
            try await wait(until: limit, for: "coaching ready") {
                self.readiness.status == .ready(mode)
            }
        }
    }

    private func makeComposition(audio: LiveE2EScenario.Audio) -> SessionComposition {
        let caption = OverlayCaptionPanel()
        caption.setEnabled(true)
        let box = OverlayBoxPanel()
        box.setEnabled(true)
        box.setDiagramsEnabled(true)

        let (events, continuation) = AsyncStream.makeStream(of: CoachingAttemptAuditEvent.self)
        Task { @MainActor [weak self] in
            for await event in events {
                self?.note(event)
            }
        }
        let composition = SessionComposition(
            brain: brain,
            artifacts: artifacts,
            overlayCaption: caption,
            overlayBox: box,
            readiness: readiness,
            errorReporter: errorReporter,
            makeAttemptAuditing: { evidence in
                LiveE2EAttemptObserver(evidence: evidence, observe: { continuation.yield($0) })
            },
            makeScreenCapture: { [screen] _ in screen },
            makeAudioSource: { [weak self] audioFormat, silenceDuration, delivery in
                let liveStreams: Set<AudioTimeline.Stream>
                switch audio {
                case .device:
                    return AggregateEchoCapture(
                        audioFormat: audioFormat,
                        localTurnDetectionSilenceDuration: silenceDuration,
                        delivery: delivery)
                case .fixture: liveStreams = [.microphone, .system]
                case .fixtureNoSystem: liveStreams = [.microphone]
                case .fixtureNoMicrophone: liveStreams = [.system]
                }
                let source = FixtureAudioSource(
                    liveStreams: liveStreams, audioFormat: audioFormat, delivery: delivery)
                self?.fixtureSource = source
                return source
            })
        // The one lifecycle consequence a failure has here: stop so the evidence seals. Runtime
        // context everywhere, so no alert can ever block this process.
        errorReporter.onFatal = { [weak self] reason in
            guard let self else { return }
            self.sessionEnd = reason
            self.drain = self.composition.stop(reason: reason)
        }
        return composition
    }

    private func makePreferences(for scenario: LiveE2EScenario) throws -> BrainPreferences {
        // A private suite, cleared first, so the developer's own route and switches are never read
        // or written. It holds only route and switch settings, never a secret.
        guard let defaults = UserDefaults(suiteName: Self.defaultsSuite) else {
            throw Failure.defaultsSuiteUnavailable
        }
        defaults.removePersistentDomain(forName: Self.defaultsSuite)
        let preferences = BrainPreferences(defaults: defaults)
        preferences.route = BrainRoute(
            primary: Self.defaultTarget(for: scenario.brain.primary),
            fallbackTargets: scenario.brain.fallbacks.map(Self.defaultTarget(for:)))
        preferences.disabledTools = Set(scenario.capabilities.disabledTools)
        preferences.disabledSkills = Set(scenario.capabilities.disabledSkills)
        return preferences
    }

    private func detectCLIs(
        for scenario: LiveE2EScenario
    ) async throws -> [BrainProvider: DetectedAgentCLI] {
        let detected = await brain.detector.detectAllAsync()
        var clis = Dictionary(uniqueKeysWithValues: detected.map { ($0.provider, $0) })
        if scenario.cli[.claudeCode] == .stub {
            guard let stub = options.claudeCLIOverride else { throw Failure.stubUnavailable }
            // Presence and sign-in are all a Start checks. The stub then fails at the request stage,
            // where every local-agent process failure is temporary, which is what F04 needs.
            clis[.claudeCode] = DetectedAgentCLI(
                provider: .claudeCode,
                executableURL: stub,
                authenticationStatus: .signedIn,
                supportedFeatures: clis[.claudeCode]?.supportedFeatures ?? [])
        }
        return clis
    }

    private func synthesizeLines(of scenario: LiveE2EScenario) throws -> [Int: SpokenClips] {
        func voice(for speaker: Speaker) -> String {
            speaker == .me ? scenario.voices.me : scenario.voices.them
        }
        var clips: [Int: SpokenClips] = [:]
        for (index, step) in scenario.steps.enumerated() {
            guard case .say(let line, let overlap, _) = step else { continue }
            clips[index] = SpokenClips(
                line: try speech.samples(for: line.text, voice: voice(for: line.speaker)),
                overlap: try overlap.map {
                    try speech.samples(for: $0.text, voice: voice(for: $0.speaker))
                })
        }
        return clips
    }

    private func play(
        _ clips: SpokenClips, line: LiveE2EScenario.Line, overlap: LiveE2EScenario.Overlap?
    ) {
        fixtureSource?.schedule(clips.line, on: Self.stream(for: line.speaker))
        if let overlap, let overlapSamples = clips.overlap {
            fixtureSource?.schedule(
                overlapSamples, on: Self.stream(for: overlap.speaker),
                afterSeconds: overlap.afterSeconds)
        }
    }

    // MARK: - Waits

    /// Wait for the first attempt after `mark` whose trigger matches, then for it to finish, then for
    /// anything it queued to finish, so the next step starts from a settled conversation.
    private func awaitAttempt(
        step: Int,
        since mark: Int,
        onStart: (() -> Void)?,
        matching: (TriggerReason) -> Bool
    ) async throws {
        let limit = Date().addingTimeInterval(Self.attemptTimeout)
        var matched: Int?
        try await wait(until: limit, for: "step \(step)'s coaching attempt to start") {
            matched = self.firstStartedAttempt(since: mark, matching: matching)
            return matched != nil
        }
        guard let attemptID = matched else { return }
        onStart?()
        try await wait(until: limit, for: "attempt \(attemptID) to finish") {
            self.finishedAttemptIDs.contains(attemptID)
        }
        stepAttemptLines.append("{\"attempt\":\(attemptID),\"step\":\(step)}")
        try TranscriptionBenchmarkFiles.writeText(
            stepAttemptLines.joined(separator: "\n") + "\n",
            named: "steps.jsonl", to: options.outputDirectory)
        try await Task.sleep(for: Self.settleDuration)
        try await wait(until: limit, for: "queued coaching attempts to finish") {
            self.startedAttemptIDs.isSubset(of: self.finishedAttemptIDs)
        }
    }

    private func wait(
        until limit: Date, for description: String, _ condition: () -> Bool
    ) async throws {
        while !condition() {
            try checkAbort()
            if !expectsSessionEnd, let sessionEnd {
                throw Failure.unexpectedSessionEnd(String(describing: sessionEnd))
            }
            let now = Date()
            guard now < limit, now < runDeadline else { throw Failure.timedOut(description) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func checkAbort() throws {
        if FileManager.default.fileExists(
            atPath: options.outputDirectory.appendingPathComponent("abort").path) {
            throw Failure.aborted
        }
    }

    private func note(_ event: CoachingAttemptAuditEvent) {
        switch event {
        case .started(let started):
            attemptEvents.append(.started(id: started.attemptID, reason: started.reason))
        case .finished(let finished):
            attemptEvents.append(.finished(id: finished.attemptID))
        }
    }

    private func firstStartedAttempt(since mark: Int, matching: (TriggerReason) -> Bool) -> Int? {
        for event in attemptEvents.dropFirst(mark) {
            if case .started(let id, let reason) = event, matching(reason) { return id }
        }
        return nil
    }

    private var startedAttemptIDs: Set<Int> {
        Set(attemptEvents.compactMap { if case .started(let id, _) = $0 { id } else { nil } })
    }

    private var finishedAttemptIDs: Set<Int> {
        Set(attemptEvents.compactMap { if case .finished(let id) = $0 { id } else { nil } })
    }

    private func writeFailure(_ message: String) {
        var object: [String: Any] = ["schemaVersion": 1, "status": "failed", "error": message]
        if let currentStep { object["step"] = currentStep }
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? TranscriptionBenchmarkFiles.write(
            data, named: "live-e2e-error.json", to: options.outputDirectory)
    }

    private static func defaultTarget(for provider: BrainProvider) -> BrainTarget {
        BrainTarget(provider: provider, modelID: BrainModelCatalog.defaultModel(for: provider).id)
    }

    private static func stream(for speaker: Speaker) -> AudioTimeline.Stream {
        speaker == .me ? .microphone : .system
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

    func brainTargetDidChange(_ target: BrainTarget?) {}

    func brainRecoveryDidChange(_ provider: BrainProvider?) {
        composition?.brainRecoveryDidChange(provider)
    }

    func brainCycleDidFail(_ provider: BrainProvider) {
        composition?.brainCycleDidFail(provider)
    }
}
