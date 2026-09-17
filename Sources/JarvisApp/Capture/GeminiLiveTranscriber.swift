import Foundation
import JarvisCore

/// Design: wiki/architecture.md#resilience
///
/// SECURITY: the API key travels in the connect URL's query string. Never log, interpolate, or
/// stringify that URL or a `URLRequest` built from it; diagnostics use `redactedEndpoint`.
///
/// `@unchecked Sendable`: stream state is guarded by `lock`, except `drainTimer`, which is confined
/// to the main queue. Lock order is documented on `WebSocketConnection`.
final class GeminiLiveTranscriber: TranscriptionSession, WebSocketConnectionAdapter,
    @unchecked Sendable {
    var onTurnEnd: (@Sendable (_ transcriptBoundary: Int) -> Void)?
    var onSilence: (@Sendable (TimeInterval) -> Void)?
    var onTranscriptionWorkChanged: (@Sendable (Bool) -> Void)?
    var onConnectionStateChange: (@Sendable (TranscriptionConnectionState) -> Void)?
    var onTerminalFailure: (@Sendable (ProviderFailure) -> Void)?
    var onCaptureHeartbeat: (@Sendable (CaptureHeartbeat) -> Void)?

    private let model: GeminiTranscriptionModel
    private let expectedLanguages: [TranscriptionLanguage]
    private let vocabularyKeywords: [String]
    private let mode: GeminiTranscriptionMode
    private let audioFormat: TranscriptionAudioFormat
    private let speaker: Speaker
    private let clock: Clock
    private let sessionStart: TimeInterval
    private let maxBufferedAudioSeconds: TimeInterval
    private let goAwayGraceTimeout: TimeInterval
    private let benchmark: TranscriptionBenchmarkInstrumentation?
    private var coachingCoordinator: TranscriptionCoachingCoordinator!
    private let continuityReporter: RealtimeContinuityReporter
    private var connection: WebSocketConnection!

    private let lock = NSLock()
    private var drainTimer: Timer?
    /// Completions match chunks by `token`, not `Data`: `sendAudio` can evict the head while its
    /// send is in flight, and silent PCM makes byte-identical chunks common.
    private var bufferedAudio: [(token: UInt64, data: Data)] = []
    private var nextChunkToken: UInt64 = 0
    private var bufferedByteCount = 0
    /// Keeps the turn open while Gemini may still be recognizing sent audio. Set by voice-activity
    /// start (the earliest signal) and interim frames. Cleared by a finalized transcript, never by
    /// `ACTIVITY_END`, whose order against the final is not guaranteed. Also cleared on socket
    /// open, retry, terminate, and stop so a lost final cannot wedge it.
    private var recognitionInFlight = false
    private var isSending = false         // one in-flight audio send at a time, preserves order
    private var draining = false
    private var stopped = true

    init(
        apiKey: String,
        model: GeminiTranscriptionModel,
        expectedLanguages: [TranscriptionLanguage],
        vocabularyKeywords: [String] = [],
        mode: GeminiTranscriptionMode = .verbatim,
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
        goAwayGraceTimeout: TimeInterval = 5,
        networkStatus: @escaping @Sendable () -> String = { "unavailable" },
        activity: (any ActivityEventRecording)? = nil,
        benchmark: TranscriptionBenchmarkInstrumentation? = nil
    ) {
        self.model = model
        self.expectedLanguages = TranscriptionLanguage.canonicalizing(expectedLanguages)
        self.vocabularyKeywords = vocabularyKeywords
        self.mode = mode
        self.audioFormat = audioFormat
        self.speaker = speaker
        self.clock = clock
        self.sessionStart = sessionStart
        self.maxBufferedAudioSeconds = maxBufferedAudioSeconds
        self.goAwayGraceTimeout = goAwayGraceTimeout
        self.benchmark = benchmark
        self.continuityReporter = RealtimeContinuityReporter(
            speaker: speaker,
            clock: clock,
            sessionStart: sessionStart,
            boundary: .gemini,
            // Voice-activity frames are not reported to the witness, so expecting server speech
            // events would flag every normal utterance.
            expectsServerSpeechEvents: false)
        self.connection = WebSocketConnection(
            adapter: self,
            logPrefix: "Jarvis Gemini [\(speaker.rawValue)]",
            source: .transcription(.gemini),
            openDetail: "endpoint=\(GeminiLiveSession.redactedEndpoint) model=\(model.rawValue) "
                + "expected-languages="
                + (self.expectedLanguages.isEmpty
                    ? "automatic"
                    : self.expectedLanguages.map(\.rawValue).joined(separator: ",")),
            apiKey: apiKey,
            policy: SocketLifecyclePolicy(
                source: .transcription(.gemini),
                // Short first-connect budget: past three attempts the cause is the key, the region,
                // or the network, and the session should say so.
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
    }

    func connect() {
        lock.lock()
        stopped = false; draining = false; isSending = false; recognitionInFlight = false
        lock.unlock()
        coachingCoordinator.start()
        connection.connect()
        continuityReporter.start()
    }

    func updateAPIKey(_ apiKey: String, for credential: Credential) {
        guard credential == .geminiAPIKey else { return }
        connection.updateAPIKey(apiKey)
    }

    func stop() {
        // Stop the connection first: its `stopped` turns every in-flight timer and socket callback
        // into a no-op.
        connection.stop()
        lock.lock()
        stopped = true
        draining = false
        isSending = false
        recognitionInFlight = false
        bufferedAudio.removeAll(keepingCapacity: false)
        bufferedByteCount = 0
        lock.unlock()
        // `drainTimer` is set on main without `lock`, so read, invalidate, and nil it there too.
        DispatchQueue.main.async { [weak self] in
            self?.drainTimer?.invalidate(); self?.drainTimer = nil
        }
        continuityReporter.stop()
        coachingCoordinator.stop()
    }

    // MARK: - Socket lifecycle

    func makeRequest(apiKey: String) -> URLRequest {
        // Never log this request or its URL: the key travels in the query string.
        URLRequest(url: GeminiLiveSession.connectURL(apiKey: apiKey))
    }

    func configureSession(on lease: WebSocketConnection.Lease) {
        let setup = GeminiLiveSession.setupMessage(
            model: model, languages: expectedLanguages, vocabulary: vocabularyKeywords, mode: mode)
        guard let data = try? JSONSerialization.data(withJSONObject: setup),
              let text = String(data: data, encoding: .utf8) else {
            connection.fail(lease, cause: ProviderFailure(
                source: source, stage: .transport, category: .unknown,
                disposition: .temporary, identity: .init(),
                message: "could not encode Gemini setup message"))
            return
        }
        connection.send(.string(text), on: lease) { _ in }
    }

    func classifyHandshake(status: Int) -> ProviderFailure {
        GeminiFailureClassifier.classify(
            httpStatus: status, body: nil, source: source, stage: .handshake)
    }

    /// Gemini reports a rejected key, a retired model, and an unsupported request all as close code
    /// 1008; only the reason text tells them apart.
    func classifyClose(code: Int, reason: String?) -> ProviderFailure {
        GeminiFailureClassifier.classify(closeCode: code, reason: reason, source: source)
    }

    /// Gemini warns with a `goAway` frame, not a close code, so a bare 1001 is a fault.
    func isExpectedRotation(closeCode: Int) -> Bool { false }

    func connectionWillOpen(_ lease: WebSocketConnection.Lease) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        isSending = false
        recognitionInFlight = false
        draining = false
        lock.unlock()
    }

    func connectionDidBecomeReady(_ lease: WebSocketConnection.Lease, replacement: Bool) {
        lock.lock(); let isStopped = stopped; lock.unlock()
        guard !isStopped else { return }
        jlog("Jarvis Gemini [\(speaker.rawValue)]: transcription session ready "
             + "(socket #\(lease.generation))")
        benchmark?.observer.record(.init(
            kind: .ready,
            provider: TranscriptionProvider.gemini.rawValue,
            model: model.rawValue,
            speaker: speaker.rawValue,
            generation: lease.generation,
            observedAt: clock.now()))
        updateWorkFlag()
        pumpIfPossible()
    }

    func connectionWillRetry(_ lease: WebSocketConnection.Lease, attempt: Int) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        isSending = false
        recognitionInFlight = false
        lock.unlock()
        updateWorkFlag()
    }

    /// Guarded on `stopped`: a failure racing Stop must not show an error for a user-ended session.
    func connectionDidTerminate(_ failure: ProviderFailure) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        isSending = false
        recognitionInFlight = false
        lock.unlock()
        updateWorkFlag()
        onTerminalFailure?(failure)
    }

    func connectionWillClose(_ task: URLSessionWebSocketTask) {
        // Best-effort end-of-stream so Gemini finalizes the last utterance. Fire-and-forget: Stop
        // must not wait on network I/O.
        guard let data = try? JSONSerialization.data(
                withJSONObject: GeminiLiveSession.audioStreamEnd()),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
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
        let token = nextChunkToken
        nextChunkToken += 1
        bufferedAudio.append((token: token, data: pcm))
        bufferedByteCount += pcm.count
        var evicted = 0
        while audioFormat.duration(forByteCount: bufferedByteCount) > maxBufferedAudioSeconds,
              !bufferedAudio.isEmpty {
            bufferedByteCount -= bufferedAudio.removeFirst().data.count
            evicted += 1
        }
        lock.unlock()
        if evicted > 0 {
            jlog("⚠️ Jarvis Gemini [\(speaker.rawValue)] audio buffer overflow: "
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
        if !stopped, !draining, !isSending, let first = bufferedAudio.first,
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
        let frame = GeminiLiveSession.audioFrame(
            base64PCM: pcm.base64EncodedString(), sampleRate: audioFormat.sampleRate)
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8) else {
            // A local encoding bug: drop this chunk and keep the healthy socket. Encoding ran
            // off-lock, so check the lease first; `isSending` may belong to a replacement now.
            lock.lock()
            let isCurrentLease = !stopped && connection.isReady(lease)
            guard isCurrentLease else { lock.unlock(); return }
            if let first = bufferedAudio.first, first.token == token {
                bufferedByteCount -= bufferedAudio.removeFirst().data.count
            }
            isSending = false
            lock.unlock()
            updateWorkFlag()
            pumpIfPossible()
            return
        }
        connection.send(.string(text), on: lease) { [weak self] delivered in
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
        lock.lock()
        let hasPendingWork = !bufferedAudio.isEmpty || recognitionInFlight
        lock.unlock()
        coachingCoordinator.updateTranscriptionWork(hasPendingWork)
    }

    // MARK: - Receive

    /// Gemini sends every server frame, including `setupComplete`, as a binary frame of UTF-8 JSON.
    /// Keep the `.data` branch.
    func handle(_ message: URLSessionWebSocketTask.Message, on lease: WebSocketConnection.Lease) {
        let text: String
        let kind: String
        switch message {
        case .string(let value):
            text = value
            kind = "string"
        case .data(let bytes):
            guard let decoded = String(data: bytes, encoding: .utf8) else {
                // Never log frame contents: they carry user speech.
                jlog("Jarvis Gemini [\(speaker.rawValue)]: dropped non-UTF8 binary frame "
                     + "(\(bytes.count) bytes)")
                return
            }
            text = decoded
            kind = "data"
        @unknown default:
            jlog("Jarvis Gemini [\(speaker.rawValue)]: dropped unknown frame kind")
            return
        }
        guard let jsonData = text.data(using: .utf8),
              let obj = GeminiLiveSession.parseFrame(jsonData) else {
            // Never log frame contents: they carry user speech.
            jlog("Jarvis Gemini [\(speaker.rawValue)]: dropped unparsable \(kind) frame "
                 + "(\(text.utf8.count) bytes)")
            return
        }
        handleFrame(obj, on: lease)
    }

    /// The Live API has no in-band error frame; a close code is its only terminal-failure signal.
    private func handleFrame(_ message: [String: Any], on lease: WebSocketConnection.Lease) {
        // Re-check the lease: parsing ran after the connection's check and the socket may have been
        // replaced. `isCurrent` also covers `stopped`, plus task identity and generation.
        lock.lock(); let isStopped = stopped; lock.unlock()
        guard !isStopped, connection.isCurrent(lease) else { return }
        if GeminiLiveSession.isSetupComplete(message) {
            connection.acknowledgeReady(lease)
            return
        }
        if GeminiLiveSession.isGoAway(message) {
            beginDrain(lease, timeLeft: GeminiLiveSession.goAwayTimeLeft(message))
            return
        }
        if GeminiLiveSession.hasFinalizedTranscription(message) {
            // Clear on any final, even one `TranscriptFiltering` rejects: the server is done.
            lock.lock(); recognitionInFlight = false; let isDraining = draining; lock.unlock()
            if let text = GeminiLiveSession.finalTranscript(from: message, speaker: speaker) {
                continuityReporter.recordServerSpeech(
                    .transcriptionCompleted, audioTimeMilliseconds: nil,
                    socketGeneration: lease.generation)
                // Gemini reports no per-utterance start time.
                let accepted = coachingCoordinator.recordFinalizedTranscript(
                    text, spokenAt: nil, source: "gemini-live")
                benchmark?.observer.record(.init(
                    kind: .finalized,
                    provider: TranscriptionProvider.gemini.rawValue,
                    model: model.rawValue,
                    speaker: speaker.rawValue,
                    generation: lease.generation,
                    text: text,
                    observedAt: clock.now(),
                    transcriptUnavailable: !accepted))
            }
            updateWorkFlag()
            if isDraining {
                rotateNow(lease, reason: "utterance finalized during drain")
            }
            return
        }
        if GeminiLiveSession.hasInterimTranscription(message) {
            // Read only the flag. Interim text is speculative and must never reach Activity or the
            // transcript.
            lock.lock(); recognitionInFlight = true; lock.unlock()
            updateWorkFlag()
            return
        }
        if GeminiLiveSession.isVoiceActivityStart(message) {
            lock.lock(); recognitionInFlight = true; lock.unlock()
            updateWorkFlag()
            return
        }
        // Log keys only: values may carry user speech.
        jlog("Jarvis Gemini [\(speaker.rawValue)]: frame ignored "
             + "(\(message.keys.sorted().joined(separator: ",")))")
    }

    // MARK: - Drain / rotate (goAway)

    private func beginDrain(_ lease: WebSocketConnection.Lease, timeLeft: TimeInterval?) {
        lock.lock()
        // `isReady`, not `isCurrent`: a `goAway` before `setupComplete` is a socket that never
        // worked, and the connection will not rotate it for free.
        let leaseIsCurrent = !stopped && !draining && connection.isReady(lease)
        // Drain only when an utterance is in flight. An idle drain just holds back new audio for
        // the whole grace period.
        let hasUtteranceToDrain = leaseIsCurrent && recognitionInFlight
        if leaseIsCurrent { draining = true }
        lock.unlock()
        guard leaseIsCurrent else { return }
        connection.noteExpectedRotation(
            lease,
            reason: hasUtteranceToDrain ? "goAway, draining before rotation"
                                        : "goAway, nothing in flight")
        guard hasUtteranceToDrain else {
            rotateNow(lease, reason: "goAway, nothing in flight")
            return
        }
        armDrainDeadline(lease, timeLeft: timeLeft)
    }

    private func armDrainDeadline(_ lease: WebSocketConnection.Lease, timeLeft: TimeInterval?) {
        let bound: TimeInterval
        if let timeLeft, timeLeft > 0 {
            bound = min(goAwayGraceTimeout, timeLeft)
        } else {
            bound = goAwayGraceTimeout
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isDraining(lease) else { return }
            self.drainTimer?.invalidate()
            self.drainTimer = Timer.scheduledTimer(withTimeInterval: bound, repeats: false) {
                [weak self] _ in
                guard let self, self.isDraining(lease) else { return }
                self.rotateNow(lease, reason: "grace period elapsed")
            }
        }
    }

    private func isDraining(_ lease: WebSocketConnection.Lease) -> Bool {
        lock.lock(); let isDraining = draining && !stopped; lock.unlock()
        return isDraining && connection.isCurrent(lease)
    }

    private func rotateNow(_ lease: WebSocketConnection.Lease, reason: String) {
        guard isDraining(lease) else { return }
        connection.requestRotation(lease, reason: reason)
    }

    private var source: ProviderFailure.Source { .transcription(.gemini) }
}
