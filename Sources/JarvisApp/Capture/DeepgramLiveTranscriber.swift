import Foundation
import JarvisCore

/// Design: wiki/architecture.md#resilience
///
/// The API key travels in the `Authorization` header, never the URL, so the connect URL is safe to
/// log. Never log the request itself or a frame: frames carry user speech.
///
/// `@unchecked Sendable`: stream state is guarded by `lock`. `workReportLock` precedes `lock` and
/// the coaching lock, and is held from reading the work state through reporting it, so a stale
/// state can never overtake a newer one. The rest of the lock order is documented on
/// `WebSocketConnection`.
final class DeepgramLiveTranscriber: TranscriptionSession, WebSocketConnectionAdapter,
    @unchecked Sendable {
    var onTurnEnd: (@Sendable (_ transcriptBoundary: Int) -> Void)?
    var onSilence: (@Sendable (TimeInterval) -> Void)?
    var onTranscriptionWorkChanged: (@Sendable (TranscriptionWorkState) -> Void)?
    var onConnectionStateChange: (@Sendable (TranscriptionConnectionState) -> Void)?
    var onTerminalFailure: (@Sendable (ProviderFailure) -> Void)?
    var onCaptureHeartbeat: (@Sendable (CaptureHeartbeat) -> Void)?

    private let model: DeepgramTranscriptionModel
    private let expectedLanguages: [TranscriptionLanguage]
    private let audioFormat: TranscriptionAudioFormat
    private let speaker: Speaker
    private let clock: Clock
    private let sessionStart: TimeInterval
    private let maxBufferedAudioSeconds: TimeInterval
    private var coachingCoordinator: TranscriptionCoachingCoordinator!
    private let continuityReporter: RealtimeContinuityReporter
    private var connection: WebSocketConnection!

    private let lock = NSLock()
    /// Completions match chunks by `token`, not `Data`: `sendAudio` can evict the head while its
    /// send is in flight, and silent PCM makes byte-identical chunks common.
    private var bufferedAudio: [(token: UInt64, data: Data, capturedAt: TimeInterval)] = []
    private var nextChunkToken: UInt64 = 0
    private var bufferedByteCount = 0
    private let workReportLock = NSLock()
    private var assembler = DeepgramUtteranceAssembler()
    /// Deepgram times no utterance, so the pending start comes from content-free local activity.
    private var activityTracker = PCM16SpeechActivityTracker()
    private var pendingSpeech = PendingSpeechWindow()
    private var isSending = false         // one in-flight audio send at a time, preserves order
    private var stopped = true

    init(
        apiKey: String,
        model: DeepgramTranscriptionModel,
        expectedLanguages: [TranscriptionLanguage],
        audioFormat: TranscriptionAudioFormat,
        speaker: Speaker = .me,
        transcript: RollingTranscript,
        clock: Clock,
        sessionStart: TimeInterval,
        silenceTimeout: TimeInterval,
        silenceMaxInterval: TimeInterval,
        silenceIdleCutoff: TimeInterval = .infinity,
        transcriptBatchingWindow: TimeInterval = 0.4,
        maxBufferedAudioSeconds: TimeInterval = 60,
        readyTimeout: TimeInterval = 10,
        pingInterval: TimeInterval = 20,
        pongTimeout: TimeInterval = 10,
        networkStatus: @escaping @Sendable () -> String = { "unavailable" },
        activity: (any ActivityEventRecording)? = nil
    ) {
        self.model = model
        self.expectedLanguages = TranscriptionLanguage.canonicalizing(expectedLanguages)
        self.audioFormat = audioFormat
        self.speaker = speaker
        self.clock = clock
        self.sessionStart = sessionStart
        self.maxBufferedAudioSeconds = maxBufferedAudioSeconds
        self.continuityReporter = RealtimeContinuityReporter(
            speaker: speaker,
            clock: clock,
            sessionStart: sessionStart,
            boundary: .deepgram,
            // Speech-start frames are not reported to the witness, so expecting server speech
            // events would flag every normal utterance.
            expectsServerSpeechEvents: false)
        self.connection = WebSocketConnection(
            adapter: self,
            logPrefix: "Jarvis Deepgram [\(speaker.rawValue)]",
            source: .transcription(.deepgram),
            openDetail: "model=\(model.rawValue) expected-languages="
                + (self.expectedLanguages.isEmpty
                    ? "automatic"
                    : self.expectedLanguages.map(\.rawValue).joined(separator: ",")),
            apiKey: apiKey,
            policy: SocketLifecyclePolicy(
                source: .transcription(.deepgram),
                // Short first-connect budget: past three attempts the cause is the key or the
                // network, and the session should say so.
                firstConnect: RetrySchedule(maximumRetries: 2, initialDelay: 1, maximumDelay: 30),
                reconnect: RetrySchedule(maximumRetries: 6, initialDelay: 1, maximumDelay: 30)),
            readyTimeout: readyTimeout,
            pingInterval: pingInterval,
            pongTimeout: pongTimeout,
            networkStatus: networkStatus,
            transportControl: nil,
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
            onTranscriptionWorkChanged: { [weak self] state in
                self?.onTranscriptionWorkChanged?(state)
            },
            activity: activity)
    }

    func connect() {
        lock.lock()
        stopped = false; isSending = false
        assembler = DeepgramUtteranceAssembler()
        _ = activityTracker.reset()
        pendingSpeech.reset()
        lock.unlock()
        coachingCoordinator.start()
        connection.connect()
        continuityReporter.start()
    }

    func updateAPIKey(_ apiKey: String, for credential: Credential) {
        guard credential == .deepgramAPIKey else { return }
        connection.updateAPIKey(apiKey)
    }

    func stop() {
        // Stop the connection first: its `stopped` turns every in-flight timer and socket callback
        // into a no-op.
        connection.stop()
        lock.lock()
        stopped = true
        isSending = false
        assembler = DeepgramUtteranceAssembler()
        // No further audio arrives to release the detector, so close the window here too.
        _ = activityTracker.reset()
        pendingSpeech.reset()
        bufferedAudio.removeAll(keepingCapacity: false)
        bufferedByteCount = 0
        lock.unlock()
        continuityReporter.stop()
        coachingCoordinator.stop()
    }

    // MARK: - Socket lifecycle

    func makeRequest(apiKey: String) -> URLRequest {
        var request = URLRequest(url: DeepgramLiveSession.connectURL(
            model: model, languages: expectedLanguages, sampleRate: audioFormat.sampleRate))
        request.setValue(DeepgramLiveSession.authorizationValue(apiKey: apiKey),
                         forHTTPHeaderField: "Authorization")
        return request
    }

    /// Deepgram has no setup reply: the settings are query parameters. A control frame that the
    /// socket delivers proves the upgrade was accepted, and a refused one fails the send instead.
    func configureSession(on lease: WebSocketConnection.Lease) {
        connection.send(.string(DeepgramLiveSession.keepAliveMessage), on: lease) { [weak self] delivered in
            guard delivered, let self else { return }
            self.connection.acknowledgeReady(lease)
        }
    }

    func classifyHandshake(status: Int) -> ProviderFailure {
        DeepgramFailureClassifier.classify(
            httpStatus: status, body: nil, source: source, stage: .handshake)
    }

    func classifyClose(code: Int, reason: String?) -> ProviderFailure {
        DeepgramFailureClassifier.classify(closeCode: code, reason: reason, source: source)
    }

    func isExpectedRotation(closeCode: Int) -> Bool { false }

    func connectionWillOpen(_ lease: WebSocketConnection.Lease) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        isSending = false
        assembler.reset()
        lock.unlock()
    }

    func connectionDidBecomeReady(_ lease: WebSocketConnection.Lease, replacement: Bool) {
        lock.lock(); let isStopped = stopped; lock.unlock()
        guard !isStopped else { return }
        jlog("Jarvis Deepgram [\(speaker.rawValue)]: transcription session ready "
             + "(socket #\(lease.generation))")
        updateWorkFlag()
        pumpIfPossible()
    }

    func connectionWillRetry(_ lease: WebSocketConnection.Lease, attempt: Int) {
        salvageUtterance(reason: "socket retry")
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        isSending = false
        lock.unlock()
        updateWorkFlag()
    }

    /// Guarded on `stopped`: a failure racing Stop must not show an error for a user-ended session.
    func connectionDidTerminate(_ failure: ProviderFailure) {
        salvageUtterance(reason: "terminal failure")
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        isSending = false
        lock.unlock()
        updateWorkFlag()
        onTerminalFailure?(failure)
    }

    func connectionWillClose(_ task: URLSessionWebSocketTask) {
        // Best-effort end-of-stream so Deepgram finalizes the last utterance. Fire-and-forget: Stop
        // must not wait on network I/O.
        task.send(.string(DeepgramLiveSession.closeStreamMessage)) { _ in }
    }

    // MARK: - Audio

    func recordCapturedAudio(sequenceNumber: UInt64, sampleCount: Int, capturedAt: TimeInterval) {
        lock.lock(); let isStopped = stopped; lock.unlock()
        guard !isStopped else { return }
        continuityReporter.recordCapture(
            sequence: sequenceNumber, sampleCount: sampleCount, at: capturedAt - sessionStart)
    }

    func sendAudio(_ pcm: Data, sequenceNumber: UInt64, capturedAt: TimeInterval) {
        // Capture already delivers `audioFormat`'s rate; never resample here.
        continuityReporter.recordDelivery(
            sequence: sequenceNumber, pcm16: pcm, at: clock.now() - sessionStart)
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        if let active = activityTracker.observe(pcm16: pcm, at: capturedAt) {
            pendingSpeech.recordLocalSpeech(active: active, at: capturedAt - sessionStart)
        }
        let token = nextChunkToken
        nextChunkToken += 1
        bufferedAudio.append((token: token, data: pcm, capturedAt: capturedAt - sessionStart))
        bufferedByteCount += pcm.count
        var evicted = 0
        while audioFormat.duration(forByteCount: bufferedByteCount) > maxBufferedAudioSeconds,
              !bufferedAudio.isEmpty {
            bufferedByteCount -= bufferedAudio.removeFirst().data.count
            evicted += 1
        }
        lock.unlock()
        if evicted > 0 {
            jlog("⚠️ Jarvis Deepgram [\(speaker.rawValue)] audio buffer overflow: "
                 + "evicted \(evicted) oldest chunk(s)")
        }
        updateWorkFlag()
        pumpIfPossible()
    }

    private func pumpIfPossible() {
        var frame: Data?
        var frameToken: UInt64?
        var socketLease: WebSocketConnection.Lease?
        lock.lock()
        if !stopped, !isSending, let first = bufferedAudio.first,
           let lease = connection.readyLease {
            frame = first.data
            frameToken = first.token
            socketLease = lease
            isSending = true
        }
        lock.unlock()
        guard let frame, let frameToken, let socketLease else { return }
        sendFrame(frame, token: frameToken, on: socketLease)
    }

    private func sendFrame(_ pcm: Data, token: UInt64, on lease: WebSocketConnection.Lease) {
        connection.send(.data(pcm), on: lease) { [weak self] delivered in
            guard let self else { return }
            guard delivered else {
                self.lock.lock()
                // A stale lease's completion must not clear the replacement's `isSending`.
                if self.connection.isCurrent(lease) { self.isSending = false }
                self.lock.unlock()
                return
            }
            self.lock.lock()
            let isCurrentLease = !self.stopped && self.connection.isReady(lease)
            // A stale completion must not touch `isSending` or pump: that state belongs to the
            // replacement, and clearing it would allow a duplicate send.
            guard isCurrentLease else { self.lock.unlock(); return }
            if let first = self.bufferedAudio.first, first.token == token {
                self.bufferedByteCount -= self.bufferedAudio.removeFirst().data.count
            }
            self.isSending = false
            self.lock.unlock()
            self.updateWorkFlag()
            self.pumpIfPossible()
        }
    }

    private func updateWorkFlag() {
        workReportLock.lock()
        defer { workReportLock.unlock() }
        lock.lock()
        let state = pendingSpeech.state(
            queuedSince: bufferedAudio.first?.capturedAt,
            isRecognizing: assembler.hasUnresolvedSpeech)
        lock.unlock()
        coachingCoordinator.updateTranscriptionWork(state)
    }

    // MARK: - Receive

    func handle(_ message: URLSessionWebSocketTask.Message, on lease: WebSocketConnection.Lease) {
        let bytes: Data
        switch message {
        case .string(let value): bytes = Data(value.utf8)
        case .data(let value): bytes = value
        @unknown default:
            jlog("Jarvis Deepgram [\(speaker.rawValue)]: dropped unknown frame kind")
            return
        }
        guard let event = DeepgramLiveSession.parseEvent(bytes) else {
            // Never log frame contents: they carry user speech.
            jlog("Jarvis Deepgram [\(speaker.rawValue)]: dropped unparsable frame "
                 + "(\(bytes.count) bytes)")
            return
        }
        handle(event, on: lease)
    }

    private func handle(_ event: DeepgramLiveSession.Event, on lease: WebSocketConnection.Lease) {
        // Re-check the lease: parsing ran after the connection's check and the socket may have been
        // replaced. `isCurrent` also covers `stopped`, plus task identity and generation.
        lock.lock(); let isStopped = stopped; lock.unlock()
        guard !isStopped, connection.isCurrent(lease) else { return }
        let heardSpeech: Bool
        let reason: String
        switch event {
        case .results(let result):
            heardSpeech = !result.isFinal && !result.transcript.isEmpty
            reason = "endpointing"
        case .speechStarted:
            heardSpeech = true
            reason = "speech started"
        case .utteranceEnd:
            heardSpeech = false
            reason = "utterance end"
        case .error:
            // The description can echo request details, so only the kind is logged.
            jlog("Jarvis Deepgram [\(speaker.rawValue)]: server reported an error frame")
            return
        case .other:
            return
        }
        let observedAt = clock.now() - sessionStart
        lock.lock()
        if heardSpeech { pendingSpeech.recordRecognitionObserved(at: observedAt) }
        let segments = assembler.receive(event)
        lock.unlock()
        publish(segments, reason: reason)
        updateWorkFlag()
    }

    private func salvageUtterance(reason: String) {
        lock.lock()
        let segments = assembler.closeAll()
        lock.unlock()
        publish(segments, reason: reason)
    }

    /// Settles even an utterance `TranscriptFiltering` rejects, because the server is done with
    /// the audio. The assembler holds the speech unresolved until the line is in the transcript.
    private func publish(_ segments: [String], reason: String) {
        guard !segments.isEmpty else { return }
        lock.lock()
        let spokenAt = pendingSpeech.recordFinalized()
        lock.unlock()
        if let text = DeepgramLiveSession.joinedTranscript(segments, speaker: speaker) {
            coachingCoordinator.recordFinalizedTranscript(
                text, spokenAt: spokenAt, source: "deepgram-live (\(reason))")
        }
        lock.lock()
        assembler.finishPublishing()
        lock.unlock()
    }

    private var source: ProviderFailure.Source { .transcription(.deepgram) }
}
