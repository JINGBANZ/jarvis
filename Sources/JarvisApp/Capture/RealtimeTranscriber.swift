import Foundation
import JarvisCore

/// Client for the OpenAI GA Realtime API used as a **transcription session**. Streams PCM16 audio,
/// configures model-compatible turn detection, and parses transcription + speech events. The shared
/// Core coordinator publishes finalized lines and owns provider-neutral coaching triggers.
///
/// The wire contract (connect URL with `?intent=transcription`, the `session.update` payload, the
/// audio-append/commit events) is built by the pure, unit-tested `RealtimeSession` in JarvisCore.
/// GPT-4o uses server VAD. GPT Transcribe and GPT Live disable automatic turn detection and commit
/// boundaries supplied by capture-side WebRTC VAD, after the ordered FIFO has sent every matching
/// audio chunk. Provisional deltas remain lifecycle-only; finalized text is still the sole input to
/// Activity and the coaching model.
///
/// Robustness: the socket itself belongs to `WebSocketConnection`, which both socket transcribers
/// share. It waits for the server's configuration acknowledgement before reporting ready, probes
/// ready sockets with ping/pong, and reconnects with capped exponential backoff on every detected
/// send, receive, close, startup-timeout, or liveness failure. This type is its OpenAI adapter,
/// supplying the request, the `session.update` payload, the event reader, the two classifiers, and
/// the replay bookkeeping each socket handoff needs.
///
/// `streamReady`/`everStreamReady` mirror the connection's readiness under this type's own `lock`,
/// and every producer reads the mirror rather than asking the connection. That is what keeps a
/// producer's decision atomic with the replay bookkeeping it drives; see `WebSocketConnection`'s
/// header for the lock order and why the mirror exists.
///
/// `@unchecked Sendable`: every mutable field is guarded by `lock`. The four implicitly unwrapped
/// or optional collaborators (`connection`, `coachingCoordinator`, `transcriptionLifecycle`,
/// `jarvisManagedTurnCoordinator`) are assigned once in `init`, before this instance is shared, and
/// never reassigned; they are not `let` only because building them captures `self`. No timer or
/// other main-queue-confined state lives here, because the socket's timers belong to
/// `WebSocketConnection`. `continuityReporter`, `coachingCoordinator`, and `audioBuffer` guard their
/// own state, and this type calls them under the A-then-D order that header documents.
final class RealtimeTranscriber: TranscriptionSession, WebSocketConnectionAdapter,
    @unchecked Sendable {
    private enum OutboundAction {
        case audio(PCMBuffer.Claim, WebSocketConnection.Lease)
        case commit(RealtimeJarvisManagedTurnCoordinator.Turn, WebSocketConnection.Lease)
    }

    var onTurnEnd: (@Sendable (_ transcriptBoundary: Int) -> Void)?
    var onSilence: (@Sendable (TimeInterval) -> Void)?
    var onTranscriptionWorkChanged: (@Sendable (Bool) -> Void)?
    var onConnectionStateChange: (@Sendable (TranscriptionConnectionState) -> Void)?
    /// Fired when transcription becomes unusable, either from an unrecoverable provider rejection or
    /// after reconnection is abandoned, so the app can stop instead of lying green.
    var onTerminalFailure: (@Sendable (ProviderFailure) -> Void)?
    var onCaptureHeartbeat: (@Sendable (CaptureHeartbeat) -> Void)?

    private let model: OpenAITranscriptionModel
    private let expectedLanguages: [TranscriptionLanguage]
    private let vocabularyKeywords: [String]
    /// Who this socket is transcribing: `.me` (mic) or `.them` (system audio). Two transcribers run
    /// in parallel — one per side — feeding the same `RollingTranscript`, so the coach sees both.
    private let speaker: Speaker
    private let clock: Clock
    private let sessionStart: TimeInterval
    private let silenceDurationMs: Int
    private let noiseReduction: NoiseReductionMode
    /// `nil` for every normal coaching session. Optional chaining then skips event construction.
    private let benchmark: TranscriptionBenchmarkInstrumentation?
    /// The socket. Built in `init` because it takes this transcriber as its adapter.
    private var connection: WebSocketConnection!

    private let lock = NSLock()
    private var coachingCoordinator: TranscriptionCoachingCoordinator!
    private var transcriptionLifecycle: RealtimeTranscriptionLifecycle!
    private let continuityReporter: RealtimeContinuityReporter
    private let audioBuffer: PCMBuffer        // mic audio captured while the socket is down
    /// Present only for client-commit models. Mutated under `lock` so commit ordering is atomic with
    /// FIFO/socket state; the value itself remains Foundation-only and unit-tested in Core.
    private var jarvisManagedTurnCoordinator: RealtimeJarvisManagedTurnCoordinator?
    /// Jarvis-managed models keep only a short local pre-roll while idle. Active speech and endpoint
    /// trailing silence then enter `audioBuffer`; server-VAD models bypass this gate.
    private var jarvisManagedSpeechBuffer: SpeechGatedAudioBuffer?
    private var stopped = false
    /// This stream's own view of readiness, flipped only inside the connection's lifecycle
    /// callbacks. Producers read this, never the connection, so their decisions stay atomic with the
    /// replay bookkeeping below; see the type's header comment.
    private var streamReady = false
    private var everStreamReady = false  // distinguishes the first connect from a reconnect
    /// Closes the short handoff between snapshotting old item state and accepting new outage audio.
    /// Producers set the companion bit instead of calling into the lifecycle until initialization
    /// completes, avoiding both a missed barrier and an inverse lock order.
    private var reconnectRecoveryIsInitializing = false
    private var bufferedAudioDuringRecoveryInitialization = false
    /// Stays set until replacement readiness snapshots it. This closes the race where a producer
    /// accepts outage audio, readiness wins before its lifecycle callback, and the gate otherwise
    /// sees no untracked replay work.
    private var hasUntrackedBufferedReplayAudio = false
    /// The session id from the acknowledgement frame, handed to `connectionDidBecomeReady` so the
    /// ready line can name it. The connection has no way to know it.
    private var pendingSessionID: String?
    /// Realtime's `audio_start_ms` is relative to audio written on one socket. These origins map it
    /// back onto Jarvis's overall session clock, including audio buffered during reconnect backoff.
    private var pendingAudioTimelineOrigin: TimeInterval = 0
    private var activeAudioTimelineOrigin: TimeInterval = 0

    init(
        apiKey: String,
        model: OpenAITranscriptionModel,
        expectedLanguages: [TranscriptionLanguage],
        vocabularyKeywords: [String] = [],
        speaker: Speaker = .me,
        transcript: RollingTranscript,
        clock: Clock,
        sessionStart: TimeInterval,
        silenceTimeout: TimeInterval,
        silenceMaxInterval: TimeInterval,
        silenceIdleCutoff: TimeInterval = .infinity,
        silenceDurationMs: Int = 1000,
        noiseReduction: NoiseReductionMode = .auto,
        transcriptBatchingWindow: TimeInterval = 0.4,
        transcriptionTerminalTimeout: TimeInterval = 8,
        transcriptionActiveTimeout: TimeInterval = 180,
        maxBufferedAudioSeconds: TimeInterval = 60,
        jarvisManagedTurnPreRollDuration: TimeInterval = 0.3,
        readyTimeout: TimeInterval = 10,
        pingInterval: TimeInterval = 20,
        pongTimeout: TimeInterval = 10,
        networkStatus: @escaping @Sendable () -> String = { "unavailable" },
        activity: (any ActivityEventRecording)? = nil,
        benchmark: TranscriptionBenchmarkInstrumentation? = nil
    ) {
        self.model = model
        self.expectedLanguages = TranscriptionLanguage.canonicalizing(expectedLanguages)
        self.vocabularyKeywords = vocabularyKeywords
        self.speaker = speaker
        self.clock = clock
        self.sessionStart = sessionStart
        self.silenceDurationMs = silenceDurationMs
        self.noiseReduction = noiseReduction
        self.benchmark = benchmark
        self.audioBuffer = PCMBuffer(maxBytes: TranscriptionAudioFormat.pcm16Mono24k.byteCount(
            forDuration: maxBufferedAudioSeconds))
        let usesJarvisManagedTurns = model.turnDetectionStrategy == .clientCommit
        self.jarvisManagedTurnCoordinator = usesJarvisManagedTurns
            ? RealtimeJarvisManagedTurnCoordinator()
            : nil
        self.jarvisManagedSpeechBuffer = usesJarvisManagedTurns
            ? SpeechGatedAudioBuffer(maximumPreRollDuration: jarvisManagedTurnPreRollDuration)
            : nil
        self.continuityReporter = RealtimeContinuityReporter(
            speaker: speaker, clock: clock, sessionStart: sessionStart,
            // Client-commit models run with `turn_detection: null`, so the server never reports
            // speech boundaries and the local-vs-server comparison would flag every real utterance.
            expectsServerSpeechEvents: model.turnDetectionStrategy != .clientCommit)
        self.connection = WebSocketConnection(
            adapter: self,
            logPrefix: "Jarvis realtime [\(speaker.rawValue)]",
            source: .transcription(.openAI),
            openDetail: "model=\(model.rawValue) expected-languages="
                + (self.expectedLanguages.isEmpty
                    ? "automatic"
                    : self.expectedLanguages.map(\.rawValue).joined(separator: ",")),
            apiKey: apiKey,
            policy: SocketLifecyclePolicy(
                source: .transcription(.openAI),
                // A socket that has never been ready has nothing to preserve, and every attempt
                // costs the user silence with no explanation. Three attempts is enough to ride out
                // a transient refusal; past that the cause is the key, the region, or the network,
                // and the session should say so.
                firstConnect: RetrySchedule(maximumRetries: 2, initialDelay: 1, maximumDelay: 30),
                reconnect: RetrySchedule(maximumRetries: 6, initialDelay: 1, maximumDelay: 30)),
            readyTimeout: readyTimeout,
            pingInterval: pingInterval,
            pongTimeout: pongTimeout,
            networkStatus: networkStatus,
            transportControl: benchmark?.transportControl,
            onStateChange: { [weak self] state in self?.onConnectionStateChange?(state) })
        continuityReporter.onCaptureHeartbeat = { [weak self] signal in
            self?.onCaptureHeartbeat?(signal)
        }
        self.coachingCoordinator = TranscriptionCoachingCoordinator(
            speaker: speaker,
            transcript: transcript,
            clock: clock,
            sessionStart: sessionStart,
            transcriptBatchingWindow: transcriptBatchingWindow,
            silenceTimeout: silenceTimeout,
            silenceMaxInterval: silenceMaxInterval,
            silenceIdleCutoff: silenceIdleCutoff,
            silenceEnabled: speaker == .me,
            onTurnEnd: { [weak self] boundary in self?.onTurnEnd?(boundary) },
            onSilence: { [weak self] quiet in self?.onSilence?(quiet) },
            onTranscriptionWorkChanged: { [weak self] hasPendingWork in
                self?.onTranscriptionWorkChanged?(hasPendingWork)
            },
            activity: activity)
        let onFinalizedItem: (@Sendable (RealtimeTranscriptionLedger.FinalizedItem) -> Void)?
        if benchmark == nil {
            onFinalizedItem = nil
        } else {
            onFinalizedItem = { [weak self] item in
                guard let self else { return }
                self.benchmark?.observer.record(.init(
                    kind: .finalized,
                    provider: TranscriptionProvider.openAI.rawValue,
                    model: self.model.rawValue,
                    speaker: self.speaker.rawValue,
                    generation: self.connection.currentGeneration,
                    itemID: item.itemID,
                    text: item.text,
                    spokenAt: item.spokenAt.map { self.sessionStart + $0 },
                    spokenEndAt: item.spokenEndAt.map { self.sessionStart + $0 },
                    observedAt: self.clock.now(),
                    recoveredFromDeltas: item.recoveredFromDeltas,
                    transcriptUnavailable: item.isTranscriptUnavailable))
            }
        }
        self.transcriptionLifecycle = RealtimeTranscriptionLifecycle(
            speaker: speaker,
            coachingCoordinator: coachingCoordinator,
            terminalTimeout: transcriptionTerminalTimeout,
            activeTimeout: transcriptionActiveTimeout,
            // These ask the connection rather than the mirror above: the lifecycle holds its own
            // lock while it calls them, and the connection's lock is the leaf both may take.
            isCurrentGeneration: { [weak self] generation in
                self?.connection.isLive(generation: generation) == true
            },
            isReady: { [weak self] generation in
                self?.connection.isReady(generation: generation) == true
            },
            discardConfirmedAudio: { [weak self] boundary in
                _ = self?.audioBuffer.discardSent(through: boundary)
            },
            onFinalizedItem: onFinalizedItem)
    }

    func connect() {
        // Start clean: clear the stopped flag AND any stale recovery state from a prior session.
        lock.lock()
        stopped = false
        streamReady = false
        // Readiness selects the retry budget and how an exhausted budget is categorized, so a fresh
        // session must start as never-ready even if this instance ran one before.
        everStreamReady = false
        reconnectRecoveryIsInitializing = false
        bufferedAudioDuringRecoveryInitialization = false
        hasUntrackedBufferedReplayAudio = false
        pendingSessionID = nil
        pendingAudioTimelineOrigin = 0; activeAudioTimelineOrigin = 0
        jarvisManagedTurnCoordinator?.clear()
        jarvisManagedSpeechBuffer?.clear()
        lock.unlock()
        transcriptionLifecycle.start()
        connection.connect()
        continuityReporter.start()
    }

    /// Keep a healthy socket in place; the replacement credential is picked up if this side later
    /// reconnects. This avoids destroying live transcript state merely because Settings saved a key.
    func updateAPIKey(_ apiKey: String, for credential: Credential) {
        guard credential == .openAIAPIKey else { return }
        connection.updateAPIKey(apiKey)
    }

    func stop() {
        // The connection first: its `stopped` is what makes every timer and socket callback already
        // in flight a no-op, including one racing this Stop from off the main queue.
        connection.stop()
        lock.lock()
        stopped = true
        streamReady = false
        reconnectRecoveryIsInitializing = false
        bufferedAudioDuringRecoveryInitialization = false
        hasUntrackedBufferedReplayAudio = false
        pendingSessionID = nil
        audioBuffer.clear()             // atomic with `stopped`: no producer can append after this
        jarvisManagedTurnCoordinator?.clear()
        jarvisManagedSpeechBuffer?.clear()
        lock.unlock()
        continuityReporter.stop()
        transcriptionLifecycle.stop()
    }

    func makeRequest(apiKey: String) -> URLRequest {
        var request = URLRequest(url: RealtimeSession.connectURL())
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    func configureSession(on lease: WebSocketConnection.Lease) {
        // Resolve .auto against the live default-input device each session, so a reconnect after a
        // device swap (e.g. plugging in AirPods) picks the right profile.
        let profile = NoiseReduction.profile(mode: noiseReduction, micProximity: InputDeviceProximity.current())
        let update = RealtimeSession.sessionUpdate(
            model: model,
            speaker: speaker,
            expectedLanguages: expectedLanguages,
            keywords: vocabularyKeywords,
            silenceDurationMs: silenceDurationMs,
            noiseReduction: profile)
        guard let data = try? JSONSerialization.data(withJSONObject: update),
              let text = String(data: data, encoding: .utf8) else {
            connection.fail(lease, cause: ProviderFailure(
                source: source, stage: .transport, category: .unknown,
                disposition: .temporary, identity: .init(),
                message: "could not encode the transcription session configuration"))
            return
        }
        connection.send(.string(text), on: lease) { _ in }
    }

    /// Records the first content-free checkpoint on the delivery queue using the timestamp assigned
    /// inside the IOProc. This preserves capture-to-delivery timing without locking the audio thread.
    func recordCapturedAudio(sequenceNumber: UInt64, sampleCount: Int,
                             capturedAt: TimeInterval) {
        lock.lock(); let isStopped = stopped; lock.unlock()
        guard !isStopped else { return }
        continuityReporter.recordCapture(
            sequence: sequenceNumber, sampleCount: sampleCount, at: capturedAt - sessionStart)
    }

    func sendAudio(_ pcm: Data, sequenceNumber: UInt64, capturedAt: TimeInterval) {
        // GPT-4o sends every chunk; client-commit models release only bounded pre-roll and
        // endpoint-gated speech.
        // Eligible audio enters one ordered FIFO. Local send completion moves it into a bounded
        // recovery tail because only later server item lifecycle can retire that prefix safely.
        let observedAt = clock.now() - sessionStart
        let sessionRelativeCaptureAt = capturedAt - sessionStart
        let chunk = PCMBuffer.Chunk(
            data: pcm,
            sequenceNumber: sequenceNumber,
            capturedAt: sessionRelativeCaptureAt,
            duration: TranscriptionAudioFormat.pcm16Mono24k.duration(forByteCount: pcm.count))
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        let connectionUnavailable = !streamReady
        let bufferingForReconnect = everStreamReady && !streamReady
        let readyChunks = jarvisManagedSpeechBuffer?.append(chunk) ?? [chunk]
        let evicted = appendToAudioBuffer(readyChunks)
        let publishReplayBarrier = bufferingForReconnect && !readyChunks.isEmpty
            && !reconnectRecoveryIsInitializing
        if bufferingForReconnect, !readyChunks.isEmpty {
            hasUntrackedBufferedReplayAudio = true
            if reconnectRecoveryIsInitializing {
                bufferedAudioDuringRecoveryInitialization = true
            }
        }
        lock.unlock()
        if publishReplayBarrier {
            transcriptionLifecycle.recordBufferedReplayAudio()
        }
        continuityReporter.recordDelivery(sequence: sequenceNumber, pcm16: pcm, at: observedAt)
        reportBufferEviction(evicted, connectionUnavailable: connectionUnavailable)
        pumpAudioIfReady()
    }

    func recordLocalSpeechEvent(
        _ event: LocalSpeechEvent,
        throughSequenceNumber: UInt64
    ) {
        guard model.turnDetectionStrategy == .clientCommit else { return }
        switch event {
        case .started:
            jlog("Jarvis realtime [\(speaker.rawValue)]: local speech started")
            transcriptionLifecycle.recordLocalSpeechStarted()
            lock.lock()
            guard !stopped else { lock.unlock(); return }
            let connectionUnavailable = !streamReady
            let bufferingForReconnect = everStreamReady && !streamReady
            let readyChunks = jarvisManagedSpeechBuffer?.speechStarted() ?? []
            let evicted = appendToAudioBuffer(readyChunks)
            let publishReplayBarrier = bufferingForReconnect && !readyChunks.isEmpty
                && !reconnectRecoveryIsInitializing
            if bufferingForReconnect, !readyChunks.isEmpty {
                hasUntrackedBufferedReplayAudio = true
                if reconnectRecoveryIsInitializing {
                    bufferedAudioDuringRecoveryInitialization = true
                }
            }
            lock.unlock()
            if publishReplayBarrier {
                transcriptionLifecycle.recordBufferedReplayAudio()
            }
            reportBufferEviction(evicted, connectionUnavailable: connectionUnavailable)
            pumpAudioIfReady()
        case .ended(let startedAt, let commitAt):
            jlog("Jarvis realtime [\(speaker.rawValue)]: local speech ended "
                 + "(through sequence \(throughSequenceNumber))")
            transcriptionLifecycle.recordLocalSpeechEnded()
            lock.lock()
            guard !stopped else { lock.unlock(); return }
            jarvisManagedSpeechBuffer?.speechEnded()
            jarvisManagedTurnCoordinator?.recordTurn(
                startedAt: max(0, startedAt - sessionStart),
                committedThroughAt: max(0, commitAt - sessionStart),
                throughSequenceNumber: throughSequenceNumber)
            lock.unlock()
            pumpAudioIfReady()
        }
    }

    /// Move speech-gated chunks into the reconnect-safe FIFO. Callers serialize the Jarvis-managed
    /// speech gate with turn/socket state under `lock`; `PCMBuffer` protects its own storage.
    private func appendToAudioBuffer(_ chunks: [PCMBuffer.Chunk]) -> [PCMBuffer.Chunk] {
        chunks.flatMap { chunk in
            audioBuffer.append(
                chunk.data,
                sequenceNumber: chunk.sequenceNumber,
                capturedAt: chunk.capturedAt,
                duration: chunk.duration)
        }
    }

    private func reportBufferEviction(
        _ evicted: [PCMBuffer.Chunk],
        connectionUnavailable: Bool
    ) {
        guard !evicted.isEmpty else { return }
        benchmark?.observer.record(.init(
            kind: .bufferEviction,
            provider: TranscriptionProvider.openAI.rawValue,
            model: model.rawValue,
            speaker: speaker.rawValue,
            generation: connection.currentGeneration,
            observedAt: clock.now(),
            evictedChunks: evicted.count,
            oldestReplaySequence: evicted.compactMap(\.sequenceNumber).min()))
        let recoveryWasActive = transcriptionLifecycle.recordReplayCoverageLoss()
        continuityReporter.recordBufferEviction(
            evicted,
            replayCoverageAtRisk: connectionUnavailable || recoveryWasActive)
    }

    private func pumpAudioIfReady() {
        var action: OutboundAction?
        var droppedTurns: [RealtimeJarvisManagedTurnCoordinator.Turn] = []
        lock.lock()
        // Both halves are required. `streamReady` says this stream's own replay bookkeeping has
        // settled for the current socket; the lease says which socket to address. Asking only the
        // connection could send audio into a socket that is ready but whose replacement handoff has
        // not run yet.
        guard !stopped, streamReady, let lease = connection.readyLease else {
            lock.unlock(); return
        }
        if jarvisManagedTurnCoordinator != nil {
            if let retainedSequence = audioBuffer.oldestRetainedSequenceNumber {
                droppedTurns = jarvisManagedTurnCoordinator?.discardPendingTurns(
                    before: retainedSequence) ?? []
            }
            if let turn = jarvisManagedTurnCoordinator?.takeReadyCommit() {
                action = .commit(turn, lease)
            } else if let nextSequence = audioBuffer.nextQueuedSequenceNumber,
                      jarvisManagedTurnCoordinator?.allowsSendingAudio(
                        sequenceNumber: nextSequence) == true,
                      let claim = audioBuffer.claimNext() {
                action = .audio(claim, lease)
            }
        } else if let claim = audioBuffer.claimNext() {
            action = .audio(claim, lease)
        }
        lock.unlock()
        reportDroppedJarvisManagedTurns(droppedTurns)
        switch action {
        case .audio(let claim, let lease):
            sendAudioClaim(claim, on: lease)
        case .commit(let turn, let lease):
            sendJarvisManagedCommit(turn, on: lease)
        case nil:
            break
        }
    }

    private func reportDroppedJarvisManagedTurns(
        _ turns: [RealtimeJarvisManagedTurnCoordinator.Turn]
    ) {
        guard !turns.isEmpty else { return }
        let unbound = turns.count(where: \.needsInitialItemBinding)
        transcriptionLifecycle.discardUnboundLocalTurns(unbound)
        transcriptionLifecycle.recordReplayCoverageLoss()
        jlog("Jarvis realtime [\(speaker.rawValue)]: dropped \(turns.count) local turn "
             + "boundary/boundaries outside retained replay audio")
    }

    private func sendAudioClaim(_ claim: PCMBuffer.Claim, on lease: WebSocketConnection.Lease) {
        let socketGeneration = lease.generation
        guard let sequence = claim.chunk.sequenceNumber,
              let data = try? JSONSerialization.data(withJSONObject: RealtimeSession.appendAudio(
                base64PCM: claim.chunk.data.base64EncodedString())),
              let text = String(data: data, encoding: .utf8) else {
            _ = audioBuffer.retry(claim)
            return
        }
        continuityReporter.recordSendAttempt(
            sequence: sequence, socketGeneration: socketGeneration)
        connection.send(.string(text), on: lease) { [weak self] delivered in
            guard let self else { return }
            guard delivered else {
                // The connection retires the socket for us. Its state transition releases the
                // current FIFO claim while no producer can select this failed socket; retrying
                // before that transition would let a racing producer send the same head on the
                // dead task.
                self.continuityReporter.recordSendFailure(
                    sequence: sequence, socketGeneration: socketGeneration)
                return
            }
            self.continuityReporter.recordSendSuccess(
                sequence: sequence, socketGeneration: socketGeneration)
            self.lock.lock()
            let isCurrentLease = !self.stopped && self.streamReady
                && self.connection.isReady(lease)
            let completion = isCurrentLease ? self.audioBuffer.completeSend(claim) : nil
            if completion != nil {
                self.jarvisManagedTurnCoordinator?.recordAudioSent(sequenceNumber: sequence)
            }
            self.lock.unlock()
            if let completion {
                self.reportBufferEviction(completion.evicted, connectionUnavailable: false)
                self.pumpAudioIfReady()
            }
        }
    }

    private func sendJarvisManagedCommit(
        _ turn: RealtimeJarvisManagedTurnCoordinator.Turn,
        on lease: WebSocketConnection.Lease
    ) {
        let socketGeneration = lease.generation
        let eventID = "jarvis-commit-\(socketGeneration)-\(turn.id)"
        guard let data = try? JSONSerialization.data(
            withJSONObject: RealtimeSession.commitAudio(eventID: eventID)),
              let text = String(data: data, encoding: .utf8) else {
            connection.fail(lease, cause: ProviderFailure(
                source: source, stage: .transport, category: .unknown,
                disposition: .temporary, identity: .init(),
                message: "could not encode Jarvis-managed turn commit"))
            return
        }
        connection.send(.string(text), on: lease) { [weak self] delivered in
            guard let self, delivered else { return }
            self.lock.lock()
            let isCurrentLease = !self.stopped && self.streamReady
                && self.connection.isReady(lease)
            if isCurrentLease {
                self.jarvisManagedTurnCoordinator?.recordCommitSendCompleted(turnID: turn.id)
            }
            self.lock.unlock()
            if isCurrentLease {
                jlog("Jarvis realtime [\(self.speaker.rawValue)]: local turn commit sent "
                     + "(turn \(turn.id), through sequence \(turn.throughSequenceNumber))")
                self.benchmark?.observer.record(.init(
                    kind: .clientCommit,
                    provider: TranscriptionProvider.openAI.rawValue,
                    model: self.model.rawValue,
                    speaker: self.speaker.rawValue,
                    generation: socketGeneration,
                    itemID: "local-turn-\(turn.id)",
                    audioBoundaryAt: self.sessionStart + turn.committedThroughAt,
                    observedAt: self.clock.now()))
                self.pumpAudioIfReady()
            }
        }
    }

    /// OpenAI sends every server event as a text frame, so a binary one is not ours to read.
    func handle(_ message: URLSessionWebSocketTask.Message, on lease: WebSocketConnection.Lease) {
        guard case .string(let text) = message else { return }
        handleEvent(text, on: lease)
    }

    func classifyHandshake(status: Int) -> ProviderFailure {
        // OpenAI rejects a bad key in-band after a successful upgrade, so a refused handshake is the
        // edge itself refusing: region, VPN exit, wrong URL.
        OpenAIFailureClassifier.classify(
            httpStatus: status, body: nil, source: source, stage: .handshake)
    }

    /// OpenAI closes a rejected session with 3000 and `<type>.<code>` after the in-band error event.
    /// Classifying the close as well covers the case where the event was not recognized.
    func classifyClose(code: Int, reason: String?) -> ProviderFailure {
        OpenAIFailureClassifier.classify(closeCode: code, reason: reason, source: source)
    }

    /// A server "going away" (1001) is a routine rotation or restart we just reconnect through, even
    /// when no `session_expired` error preceded it: the two can arrive in either order.
    func isExpectedRotation(closeCode: Int) -> Bool {
        closeCode == URLSessionWebSocketTask.CloseCode.goingAway.rawValue
    }

    private func handleEvent(_ text: String, on lease: WebSocketConnection.Lease) {
        let socketGeneration = lease.generation
        // A buffered message can still arrive after an intentional Stop; don't mutate the transcript
        // or log on a torn-down pipeline (mirrors the failure/close-path gates).
        lock.lock(); let isStopped = stopped; lock.unlock()
        if isStopped { return }
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        if RealtimeSession.isConfiguredSessionEventType(type) {
            lock.lock()
            pendingSessionID = (obj["session"] as? [String: Any])?["id"] as? String
            lock.unlock()
            connection.acknowledgeReady(lease)
            return
        }

        switch type {
        case RealtimeSession.audioBufferCommittedType:
            let commitEvent = RealtimeSession.audioBufferCommitEvent(from: obj, model: model)
            guard case .acknowledgement(let itemID) = commitEvent else {
                if commitEvent == .malformedAcknowledgement {
                    jlog("Jarvis realtime [\(speaker.rawValue)]: malformed Jarvis-managed "
                         + "commit acknowledgement")
                }
                break
            }
            lock.lock()
            let turn = jarvisManagedTurnCoordinator?.acknowledgeCommittedItem(itemID: itemID)
            lock.unlock()
            guard let turn else {
                jlog("Jarvis realtime [\(speaker.rawValue)]: unmatched Jarvis-managed commit "
                     + "acknowledgement "
                     + "(item \(itemID))")
                break
            }
            // Client-commit models have no server VAD events. The commit acknowledgement is the
            // provider-side proof for the locally timed interval, so feed that content-free boundary
            // into the same continuity matcher instead of generating false "no provider speech"
            // anomalies.
            continuityReporter.recordServerSpeech(
                .speechStarted,
                audioTimeMilliseconds: nil,
                itemID: itemID,
                sessionAudioTime: turn.startedAt,
                socketGeneration: socketGeneration)
            continuityReporter.recordServerSpeech(
                .speechStopped,
                audioTimeMilliseconds: nil,
                itemID: itemID,
                sessionAudioTime: turn.committedThroughAt,
                socketGeneration: socketGeneration)
            let recorded = transcriptionLifecycle.recordCommittedLocalTurn(
                itemID: itemID,
                startedAt: turn.startedAt,
                committedThroughAt: turn.committedThroughAt,
                consumesUnboundTurn: turn.needsInitialItemBinding,
                socketGeneration: socketGeneration)
            if recorded {
                jlog("Jarvis realtime [\(speaker.rawValue)]: local turn committed "
                     + "(item \(itemID), through sequence \(turn.throughSequenceNumber))")
            }
            pumpAudioIfReady()
        case RealtimeSession.speechStartedType:
            guard let itemID = obj["item_id"] as? String,
                  let audioStartMilliseconds = obj["audio_start_ms"] as? Int else {
                jlog("Jarvis realtime [\(speaker.rawValue)]: malformed speech_started event: \(text)")
                break
            }
            lock.lock(); let timelineOrigin = activeAudioTimelineOrigin; lock.unlock()
            let didStart = transcriptionLifecycle.recordSpeechStarted(
                itemID: itemID, audioStartMilliseconds: audioStartMilliseconds,
                timelineOrigin: timelineOrigin, socketGeneration: socketGeneration)
            if didStart {
                jlog("Jarvis realtime [\(speaker.rawValue)] speech started "
                     + "(item \(itemID), audio_start_ms \(audioStartMilliseconds))")
                continuityReporter.recordServerSpeech(.speechStarted,
                                       audioTimeMilliseconds: audioStartMilliseconds,
                                       itemID: itemID,
                                       sessionAudioTime: timelineOrigin
                                           + TimeInterval(audioStartMilliseconds) / 1_000,
                                       socketGeneration: socketGeneration)
            }
        case RealtimeSession.deltaTranscriptionType:
            guard let itemID = obj["item_id"] as? String else {
                jlog("Jarvis realtime [\(speaker.rawValue)]: delta missing item_id")
                break
            }
            if let delta = obj["delta"] as? String {
                continuityReporter.recordServerSpeech(.transcriptionDelta,
                                       audioTimeMilliseconds: nil,
                                       itemID: itemID,
                                       socketGeneration: socketGeneration)
                _ = transcriptionLifecycle.recordDelta(
                    itemID: itemID, delta: delta, socketGeneration: socketGeneration)
            }
        case RealtimeSession.completedTranscriptionType:
            // A completed utterance fragment: record it immediately (so the model's context is
            // whole), but DON'T fire the coach yet — briefly batch rapid fragments of one spoken
            // sentence into a single trigger. `audio_start_ms`, captured by the ledger on
            // speech_started, timestamps the line when it was spoken rather than when inference ended.
            guard let itemID = obj["item_id"] as? String else {
                jlog("Jarvis realtime [\(speaker.rawValue)]: completed transcription missing item_id")
                break
            }
            let transcriptText = obj["transcript"] as? String ?? ""
            benchmark?.observer.record(.init(
                kind: .providerFinal,
                provider: TranscriptionProvider.openAI.rawValue,
                model: model.rawValue,
                speaker: speaker.rawValue,
                generation: socketGeneration,
                itemID: itemID,
                text: transcriptText,
                observedAt: clock.now()))
            if let languages = RealtimeSession.detectedLanguageCodes(from: obj) {
                let detail = languages.isEmpty ? "none-reliable" : languages.joined(separator: ",")
                jlog("Jarvis realtime [\(speaker.rawValue)]: detected-languages=\(detail) "
                     + "(item \(itemID))")
            }
            lock.lock()
            jarvisManagedTurnCoordinator?.recordItemFinished(itemID: itemID)
            lock.unlock()
            continuityReporter.recordServerSpeech(.transcriptionCompleted,
                                   audioTimeMilliseconds: nil,
                                   itemID: itemID,
                                   socketGeneration: socketGeneration)
            transcriptionLifecycle.recordCompleted(
                itemID: itemID, transcript: transcriptText, socketGeneration: socketGeneration)
        case RealtimeSession.failedTranscriptionType:
            guard let itemID = obj["item_id"] as? String else {
                jlog("Jarvis realtime [\(speaker.rawValue)]: failed transcription missing item_id: \(text)")
                break
            }
            let error = Self.transcriptionErrorDescription(from: obj)
            let terminalFailure = OpenAIFailureClassifier.classify(event: obj, source: source)
                .flatMap { $0.disposition == .permanent ? $0 : nil }
            benchmark?.observer.record(.init(
                kind: .providerFinal,
                provider: TranscriptionProvider.openAI.rawValue,
                model: model.rawValue,
                speaker: speaker.rawValue,
                generation: socketGeneration,
                itemID: itemID,
                observedAt: clock.now(),
                transcriptUnavailable: true))
            lock.lock()
            jarvisManagedTurnCoordinator?.recordItemFinished(itemID: itemID)
            lock.unlock()
            continuityReporter.recordServerSpeech(.transcriptionFailed,
                                   audioTimeMilliseconds: nil,
                                   itemID: itemID,
                                   socketGeneration: socketGeneration)
            transcriptionLifecycle.recordFailed(
                itemID: itemID, error: error, socketGeneration: socketGeneration)
            if let terminalFailure { connection.reportTerminalFailure(terminalFailure) }
        case RealtimeSession.speechStoppedType:
            guard let itemID = obj["item_id"] as? String else {
                jlog("Jarvis realtime [\(speaker.rawValue)]: speech_stopped missing item_id")
                break
            }
            let rawAudioEndMilliseconds = obj["audio_end_ms"] as? Int
            let audioEndMilliseconds = rawAudioEndMilliseconds.flatMap { $0 >= 0 ? $0 : nil }
            if let rawAudioEndMilliseconds, audioEndMilliseconds == nil {
                jlog("Jarvis realtime [\(speaker.rawValue)]: speech_stopped had invalid "
                     + "audio_end_ms \(rawAudioEndMilliseconds); retaining item without end timing")
            }
            lock.lock(); let timelineOrigin = activeAudioTimelineOrigin; lock.unlock()
            continuityReporter.recordServerSpeech(.speechStopped,
                                   audioTimeMilliseconds: audioEndMilliseconds,
                                   itemID: itemID,
                                   sessionAudioTime: audioEndMilliseconds.map {
                                       timelineOrigin + TimeInterval($0) / 1_000
                                   },
                                   socketGeneration: socketGeneration)
            let endDetail = audioEndMilliseconds.map { ", audio_end_ms \($0)" } ?? ""
            jlog("Jarvis realtime [\(speaker.rawValue)] speech stopped "
                 + "(item \(itemID)\(endDetail))")
            let didStop = transcriptionLifecycle.recordSpeechStopped(
                itemID: itemID, audioEndMilliseconds: audioEndMilliseconds,
                socketGeneration: socketGeneration)
            if didStop {
                benchmark?.observer.record(.init(
                    kind: .serverEndpoint,
                    provider: TranscriptionProvider.openAI.rawValue,
                    model: model.rawValue,
                    speaker: speaker.rawValue,
                    generation: socketGeneration,
                    itemID: itemID,
                    audioBoundaryAt: audioEndMilliseconds.map {
                        sessionStart + timelineOrigin + TimeInterval($0) / 1_000
                    },
                    observedAt: clock.now()))
            }
            // Do not reset proactive silence here. Bare VAD start/stop events contain no usable
            // context; only an appended final/salvaged line begins a fresh silence interval.
        case "session.created", "transcription_session.created":
            // The WebSocket handshake succeeded, but our transcription configuration has not yet
            // been acknowledged. Stay in `connecting` and keep buffering until the updated event.
            break
        case "error":
            // A session_expired error is the server telling us this session hit its lifetime cap.
            // That is an expected rotation, not a fault: tell the connection to expect it, so the
            // close and receive failure it triggers next do not pile on scary lines or spend retry
            // budget, then replace the socket at once rather than waiting out a backoff delay for
            // churn the server announced. Any OTHER error is a real fault, logged verbatim.
            if RealtimeSession.isSessionExpired(obj) {
                connection.noteExpectedRotation(lease, reason: "reached its time limit")
                connection.requestRotation(lease, reason: "reached its time limit")
            } else {
                jlog("Jarvis realtime [\(speaker.rawValue)] error event: \(text)")
                if let failure = OpenAIFailureClassifier.classify(event: obj, source: source),
                   failure.disposition == .permanent {
                    connection.reportTerminalFailure(failure)
                }
            }
        default:
            break
        }
    }

    // MARK: - Socket lifecycle

    func connectionWillOpen(_ lease: WebSocketConnection.Lease) {
        // Idempotent: the mirror is already false after a retirement and after `connect`. Setting it
        // here keeps the rule that only these callbacks ever move it.
        lock.lock()
        if !stopped { streamReady = false }
        lock.unlock()
    }

    func connectionDidBecomeReady(_ lease: WebSocketConnection.Lease, replacement: Bool) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        let sessionID = pendingSessionID
        pendingSessionID = nil
        activeAudioTimelineOrigin = audioBuffer.oldestQueuedCaptureTime
            ?? pendingAudioTimelineOrigin
        let bufferedChunks = audioBuffer.queuedChunkCount
        let hasUntrackedReplayAudio = hasUntrackedBufferedReplayAudio
        hasUntrackedBufferedReplayAudio = false
        // Keep old-socket deltas throughout reconnect attempts so terminal failure can still salvage
        // them. Once a replacement is ready, its replayed PCM becomes authoritative and old item IDs
        // must leave before the replacement emits its own lifecycle events.
        //
        // Flipping the mirror in the same critical section as that snapshot is what makes a
        // producer see either the whole outage picture or the whole live one.
        streamReady = true
        everStreamReady = true
        lock.unlock()
        let recovery = replacement
            ? transcriptionLifecycle.markReplacementReady(
                socketGeneration: lease.generation,
                hasUntrackedReplayAudio: hasUntrackedReplayAudio)
            : nil
        let id = sessionID.map { ", session \($0)" } ?? ""
        jlog("Jarvis realtime [\(speaker.rawValue)]: transcription session ready "
             + "(socket #\(lease.generation)\(id))")
        if replacement && bufferedChunks > 0 {
            jlog("⏩ realtime [\(speaker.rawValue)] replaying \(bufferedChunks) buffered audio chunks after reconnect")
        }
        if let recovery, recovery.unresolvedItems > 0 {
            if recovery.waitingForReplay {
                jlog("Jarvis realtime [\(speaker.rawValue)] replacement session ready; waiting for "
                     + "\(recovery.unresolvedItems) replayed transcription item(s)")
            } else if recovery.fallbackItems > 0 {
                jlog("Jarvis realtime [\(speaker.rawValue)] replacement session ready without complete "
                     + "replay coverage; salvaged \(recovery.fallbackItems) interrupted item(s)")
            }
        }
        benchmark?.observer.record(.init(
            kind: .ready,
            provider: TranscriptionProvider.openAI.rawValue,
            model: model.rawValue,
            speaker: speaker.rawValue,
            generation: lease.generation,
            observedAt: clock.now(),
            replayedChunks: replacement ? bufferedChunks : nil))
        // Producers always append to the same claimed FIFO. Making readiness visible before this
        // pump is safe: a racing producer may claim the oldest chunk itself, but cannot bypass it or
        // strand the chunk it just appended.
        pumpAudioIfReady()
    }

    /// The socket carrying this stream is gone and another will follow, either after a backoff delay
    /// or at once for an expected rotation. Requeue everything the server never acknowledged, then
    /// hand the interrupted items to the recovery gate so the replacement can replay into them.
    func connectionWillRetry(_ lease: WebSocketConnection.Lease, attempt: Int) {
        let failureAt = clock.now() - sessionStart
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        // The mirror, the requeue, and the initializing flag move together. A producer must never
        // see this stream as neither ready nor initializing: it would publish a replay barrier into
        // the lifecycle before `beginReconnectRecovery` below had snapshotted the old item state.
        streamReady = false
        // Local WebSocket send completions are not server acknowledgements. Requeue the entire
        // unconfirmed tail now, while producers are excluded by this lock, so audio sent during a
        // half-open interval precedes audio captured during reconnect backoff.
        let replay = audioBuffer.prepareForReconnect()
        let droppedJarvisManagedTurns = jarvisManagedTurnCoordinator?.prepareForReconnect(
            oldestAvailableSequenceNumber: replay.oldestSequenceNumber) ?? []
        pendingAudioTimelineOrigin = replay.oldestCapturedAt ?? failureAt
        reconnectRecoveryIsInitializing = true
        bufferedAudioDuringRecoveryInitialization = false
        hasUntrackedBufferedReplayAudio = false
        lock.unlock()

        benchmark?.observer.record(.init(
            kind: .reconnectPrepared,
            provider: TranscriptionProvider.openAI.rawValue,
            model: model.rawValue,
            speaker: speaker.rawValue,
            generation: lease.generation,
            observedAt: clock.now(),
            reconnectAttempt: attempt,
            replayedChunks: replay.replayedChunks,
            evictedChunks: replay.evicted.count,
            oldestReplaySequence: replay.oldestSequenceNumber))

        let interruptedItems = transcriptionLifecycle.beginReconnectRecovery(
            replayAvailable: audioBuffer.bufferedChunkCount > 0)
        lock.lock()
        let bufferedDuringInitialization = bufferedAudioDuringRecoveryInitialization
        reconnectRecoveryIsInitializing = false
        bufferedAudioDuringRecoveryInitialization = false
        lock.unlock()
        if bufferedDuringInitialization {
            transcriptionLifecycle.recordBufferedReplayAudio()
        }
        reportDroppedJarvisManagedTurns(droppedJarvisManagedTurns)
        reportBufferEviction(replay.evicted, connectionUnavailable: true)
        // Old-socket deltas are now held by the reconnect recovery gate. They remain a fallback if
        // every handshake fails or bounded replay loses coverage, without keeping stale item IDs in
        // the replacement ledger or releasing a partial coaching turn early.
        if interruptedItems > 0 && attempt == 1 {
            jlog("Jarvis realtime [\(speaker.rawValue)] retaining \(interruptedItems) interrupted "
                 + "transcription item(s) until replacement replay is ready")
        }
        if replay.replayedChunks > 0 {
            jlog("Jarvis realtime [\(speaker.rawValue)] retained \(replay.replayedChunks) "
                 + "locally-sent audio chunks for end-to-end reconnect replay")
        }
    }

    /// Nothing follows this socket. Salvage what the stream still holds so an utterance interrupted
    /// mid-flight is not simply lost, then report the failure.
    ///
    /// Both terminal paths arrive here, an exhausted retry budget and a permanent provider
    /// rejection. The permanent one used to skip the salvage. Keeping an interrupted item is
    /// strictly better for the transcript than dropping it, and the cost is at most one salvaged
    /// fragment on a session whose key was just revoked.
    /// Guarded on `stopped`: a terminal failure already in flight when the user pressed Stop must
    /// not report one, or Activity shows a session ended by error for a session the user ended.
    func connectionDidTerminate(_ failure: ProviderFailure) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        streamReady = false
        lock.unlock()
        audioBuffer.retryInFlight()
        transcriptionLifecycle.finalizeInterrupted(reason: "socket failure")
        onTerminalFailure?(failure)
    }

    /// OpenAI needs no farewell frame: a normal close is enough for it to finalize.
    func connectionWillClose(_ task: URLSessionWebSocketTask) {}

    private static func transcriptionErrorDescription(from event: [String: Any]) -> String {
        guard let error = event["error"] as? [String: Any] else { return "unknown error" }
        let code = error["code"] as? String
        let message = error["message"] as? String
        let description = [code, message].compactMap { $0 }.joined(separator: ": ")
        return description.isEmpty ? "unknown error" : description
    }

    /// This transcriber's identity in every failure it classifies.
    private var source: ProviderFailure.Source { .transcription(.openAI) }
}
