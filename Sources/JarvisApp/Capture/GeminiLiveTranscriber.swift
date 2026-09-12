import Foundation
import JarvisCore

/// Live transcription over the Gemini Live socket. The socket itself belongs to
/// `WebSocketConnection`, which both socket transcribers share; this type is its Gemini adapter,
/// supplying the setup frame, the frame reader, the two classifiers, and the drain a `goAway`
/// needs. It carries no ledger or commit path: Gemini finalizes each utterance server-side, so
/// there are no out-of-order items to reconcile and no client-managed turn boundaries to track.
///
/// SECURITY: Gemini authenticates with a query parameter (`GeminiLiveSession.connectURL(apiKey:)`),
/// so the API key lives in the connect URL. Nothing may log, interpolate, or stringify that URL or
/// a `URLRequest` built from it. `makeRequest` hands the request straight to the connection, which
/// never logs it, and every diagnostic that names the endpoint uses
/// `GeminiLiveSession.redactedEndpoint`. Transport errors are safe to pass along because they go
/// through `TransportFailureClassifier`, whose messages come from a fixed table keyed on the error
/// code and never from the error's own description, and server close reasons reach Activity only
/// through `ProviderMessageRedaction`.
///
/// `@unchecked Sendable`: mutable stream state is guarded by `lock`. `drainTimer` is the exception:
/// it is created, read, invalidated, and nilled only from main-queue blocks (including inside
/// `stop()`, which hops to main rather than touching it under `lock`), so main-queue confinement is
/// what makes it safe. `coachingCoordinator` and `continuityReporter` guard their own state and are
/// themselves Sendable. See `WebSocketConnection`'s header for the order between this lock and the
/// connection's.
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
    /// Who this socket is transcribing: `.me` (mic) or `.them` (system audio).
    private let speaker: Speaker
    private let clock: Clock
    private let sessionStart: TimeInterval
    private let maxBufferedAudioSeconds: TimeInterval
    /// Bound on the drain-then-rotate grace period `beginDrain` arms after a `goAway` — see that
    /// method's doc comment. Capped independently of `readyTimeout`/`pongTimeout`: those bound how
    /// long a *new* socket may take to become usable, while this bounds how long an *expiring* one may
    /// keep an in-flight utterance's final transcript waiting before Jarvis rotates out from under it.
    private let goAwayGraceTimeout: TimeInterval
    /// `nil` for every normal coaching session. Optional chaining then skips event construction.
    private let benchmark: TranscriptionBenchmarkInstrumentation?
    private var coachingCoordinator: TranscriptionCoachingCoordinator!
    private let continuityReporter: RealtimeContinuityReporter
    /// The socket. Built in `init` because it takes this transcriber as its adapter.
    private var connection: WebSocketConnection!

    private let lock = NSLock()
    /// Bounds the drain-then-rotate grace period; see `beginDrain`/`armDrainDeadline`.
    private var drainTimer: Timer?
    /// Audio captured while disconnected, or not yet accepted by the live socket. Plain byte-capped
    /// FIFO: unlike `RealtimeTranscriber`'s `PCMBuffer`, there is no server audio-clock acknowledgement
    /// to correlate against, so a chunk simply leaves this queue once its send completes.
    ///
    /// Each chunk carries a monotonic `token` so a completion can identify the chunk it actually sent
    /// by identity rather than by `Data` equality: `pumpIfPossible` peeks the head and releases `lock`
    /// for the duration of `task.send`, during which `sendAudio`'s eviction loop can remove that same
    /// head. Silent (all-zero) PCM at a fixed callback length is routine — a muted mic, or system audio
    /// after echo cancellation — so byte-identical chunks are common, and matching on bytes could let a
    /// completion evict a chunk that was never transmitted.
    private var bufferedAudio: [(token: UInt64, data: Data)] = []
    private var nextChunkToken: UInt64 = 0
    private var bufferedByteCount = 0
    /// `true` from the first voice-activity-start or `interimInputTranscription` frame after a final
    /// until the matching `inputTranscription` final arrives. Gemini finalizes turns server-side with
    /// no client ledger, so this is the only local signal that recognition for already-sent audio is
    /// still in flight — see `updateWorkFlag`.
    ///
    /// Driven by BOTH signals on purpose, not just one: `voiceActivity` is Gemini's direct statement
    /// that it is hearing speech, and empirically the EARLIEST signal available — measured ~500ms
    /// before the first interim frame for the same utterance — so it closes the leading-edge gap an
    /// interim-only flag would leave between speech actually starting and the first interim naming it.
    /// Interim frames are a derived side effect of text production, not a direct speech signal. Keeping
    /// both means neither a future mode that stops emitting interims nor a single missed
    /// `ACTIVITY_START` can silently leave coaching un-gated.
    ///
    /// Only the finalized transcript ever clears it — deliberately NOT `ACTIVITY_END`. `ACTIVITY_END`
    /// landed 13ms after the final in one captured trace, but that ordering is coincidence, not a
    /// documented contract; clearing on it would reintroduce exactly the settle-before-recognition race
    /// this flag exists to close (see the P1 this field was added to fix). Do not "complete the pair"
    /// by adding an `ACTIVITY_END` clear.
    ///
    /// Bounded against a lost final (so it can never wedge true for the rest of the session): cleared
    /// unconditionally in `connectionWillOpen`, `connectionWillRetry`, `connectionDidTerminate`,
    /// and `stop`.
    private var recognitionInFlight = false
    private var isSending = false         // one in-flight audio send at a time, preserves order
    /// `true` from a `goAway` frame until the replacement socket opens (see `connectionWillOpen`,
    /// which clears it for the fresh socket). Gates `pumpIfPossible` so no NEW audio is sent to a
    /// socket Google already warned is closing. The connection notes the same warning separately,
    /// which is what makes it read the close that follows as the rotation rather than a fault.
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
            // Gemini sends voice-activity frames in live sessions, but this adapter does not consume them.
            // Without this false, the witness would flag every normal utterance as "no provider speech event."
            // Consuming these frames is a possible future improvement for more reliable mid-utterance coaching.
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
    }

    func connect() {
        lock.lock()
        stopped = false; draining = false; isSending = false; recognitionInFlight = false
        lock.unlock()
        coachingCoordinator.start()
        connection.connect()
        continuityReporter.start()
    }

    /// Keep a healthy socket in place; the replacement credential is picked up if this side later
    /// reconnects. This avoids destroying live transcript state merely because Settings saved a key.
    func updateAPIKey(_ apiKey: String, for credential: Credential) {
        guard credential == .geminiAPIKey else { return }
        connection.updateAPIKey(apiKey)
    }

    func stop() {
        // The connection first: its `stopped` is what makes every timer and socket callback already
        // in flight a no-op, and it gives `connectionWillClose` the last chance to say goodbye.
        connection.stop()
        lock.lock()
        stopped = true
        draining = false
        isSending = false
        recognitionInFlight = false     // bound: a final lost to teardown must not wedge coaching gated
        bufferedAudio.removeAll(keepingCapacity: false)
        bufferedByteCount = 0
        lock.unlock()
        // The drain timer must be read, invalidated, AND nilled on the thread that scheduled it
        // (main): one queue owning the field end to end, not just the invalidate call. It is
        // assigned from main-queue blocks without `lock` (see the type's header comment), so reading
        // it under `lock` here and only hopping to main for the `invalidate()` call would race an
        // off-main Stop against a main-queue writer assigning a replacement. `stopped` is already
        // set above and the timer body guards on it, so a fire in the gap does nothing.
        DispatchQueue.main.async { [weak self] in
            self?.drainTimer?.invalidate(); self?.drainTimer = nil
        }
        continuityReporter.stop()
        coachingCoordinator.stop()
    }

    // MARK: - Socket lifecycle

    func makeRequest(apiKey: String) -> URLRequest {
        // NEVER log this request, its `.url`, or anything derived from `connectURL`: the key travels
        // in the query string. `GeminiLiveSession.redactedEndpoint` is the only safe diagnostic form,
        // and the connection is built with it as its `openDetail`.
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

    /// A rejected API key, a retired model id, and an unsupported request all surface ONLY as close
    /// code 1008. See `GeminiFailureClassifier.classify(closeCode:reason:source:)` for the
    /// empirically-established wire behavior and how the `reason` text tells them apart.
    func classifyClose(code: Int, reason: String?) -> ProviderFailure {
        GeminiFailureClassifier.classify(closeCode: code, reason: reason, source: source)
    }

    /// Gemini warns with a `goAway` frame rather than a close code, so a bare 1001 here is a fault
    /// like any other and takes the normal backoff path.
    func isExpectedRotation(closeCode: Int) -> Bool { false }

    func connectionWillOpen(_ lease: WebSocketConnection.Lease) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        isSending = false
        // A fresh socket starts with no recognition in flight: bounds a final lost to whatever
        // socket this one is replacing (see the field's doc comment).
        recognitionInFlight = false
        // A fresh socket is not draining anything, whether this is the very first connect, a normal
        // backoff-driven reconnect, or the replacement a rotation just opened. Clearing it here
        // (rather than waiting for readiness) is what keeps a genuine failure of THIS new socket,
        // its own setup send failing for instance, on the normal budget-consuming backoff path
        // instead of being mistaken for still-expected goAway churn.
        draining = false
        lock.unlock()
    }

    /// Gemini keeps no ledger, so a replacement socket has nothing to reconcile: `replacement` only
    /// distinguishes a first connect from a later one, which nothing here needs.
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
        // Bound: whatever this socket was recognizing is now unknowable, and a final for it may
        // never arrive. Clearing here rather than only on the replacement closes the gap during the
        // backoff window itself, when there is no socket to have recognized anything.
        recognitionInFlight = false
        lock.unlock()
        updateWorkFlag()   // any still-buffered audio is now definitely unsent work
    }

    /// Guarded on `stopped`: a terminal failure already in flight when the user pressed Stop must
    /// not report one, or Activity shows a session ended by error for a session the user ended.
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
        // Best-effort: tell Gemini no more audio is coming so it can finalize the last utterance.
        // Fire-and-forget, because Stop must not block on network I/O and the socket is cancelled
        // immediately after regardless of whether this frame lands.
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
        // Capture already delivers `audioFormat`'s rate — never resample here.
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

    /// Send the oldest unsent buffered chunk if the socket is ready and nothing else is in flight.
    /// One outstanding send at a time keeps audio strictly ordered without a claim/ack structure.
    private func pumpIfPossible() {
        var frame: Data?
        var frameToken: UInt64?
        var socketLease: WebSocketConnection.Lease?
        lock.lock()
        // `!draining`: a `goAway` was seen and this socket is being drained, so new audio stays
        // queued in `bufferedAudio` (already true regardless of connection state; see that field's
        // doc comment) rather than being sent to a socket Google already warned is about to close.
        // It drains into the replacement once the rotation opens one and it reports ready.
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
            // A local encoding bug, not a transport fault — drop this one chunk and keep going
            // rather than tearing down an otherwise healthy socket. Match by `token`, not position:
            // the head may have already been evicted while this frame was being built off-lock, and
            // the chunk that failed to encode is not necessarily whatever is at the head now.
            //
            // Guard on `isCurrentLease` BEFORE touching `isSending` or pumping, same as the send
            // completion below: this runs synchronously off the lock (JSON/base64 encoding), and a
            // concurrent `stop()` or socket retirement on another thread can retire this lease in that
            // window. `isSending`/the queue at that point belong to whatever replaced this lease (or
            // to nothing, if the session stopped) — a stale write here would stomp that state exactly
            // like the send-completion bug this mirrors.
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
                // Only a completion for the CURRENT lease may clear `isSending`. A stale completion
                // from a socket that has already been replaced would otherwise clear the replacement
                // socket's in-flight-send flag and let a duplicate send through. The connection
                // carries its own lease guard, so the retirement it runs next is a safe no-op for a
                // stale lease; that guard is what keeps this failure from disrupting a healthy
                // replacement, not this check.
                if self.connection.isCurrent(lease) { self.isSending = false }
                self.lock.unlock()
                return
            }
            self.lock.lock()
            let isCurrentLease = !self.stopped && self.connection.isReady(lease)
            // A stale completion (this lease was replaced while the send was in flight) must not
            // touch `isSending` or pump: `isSending` now legitimately belongs to whatever replaced it,
            // and clearing it here would let that replacement's still-outstanding send race a second,
            // duplicate send off the queue. Return before any mutation rather than gating each one
            // separately, so nothing here can partially apply.
            guard isCurrentLease else { self.lock.unlock(); return }
            // Match by `token`, not `Data` equality: silent (all-zero) PCM at a fixed callback length
            // is routine, so byte-identical chunks are common, and equality could evict a same-bytes
            // chunk that replaced the one actually sent while `lock` was released for the send. If
            // the token no longer matches the head, that chunk was evicted — do nothing to the queue.
            if let first = self.bufferedAudio.first, first.token == token {
                self.bufferedByteCount -= self.bufferedAudio.removeFirst().data.count
            }
            self.isSending = false
            self.lock.unlock()
            self.updateWorkFlag()
            self.pumpIfPossible()
        }
    }

    /// `true` while there is either audio not yet sent to the socket OR a Gemini recognition still in
    /// flight for audio that WAS already sent (`recognitionInFlight`, driven by voice-activity-start
    /// AND interim frames — see that field's doc comment for why both) — the coordinator holds a turn
    /// open until both settle. Unsent PCM alone is too narrow: the moment the
    /// last chunk's send completes, Gemini has not necessarily finished recognizing it, and if the
    /// OTHER speaker's transcript finalizes first, its batching timer could admit an automatic
    /// coaching attempt while this speaker's utterance is still mid-recognition on a perfectly healthy
    /// socket. `recognitionInFlight` is bounded against a lost final (see its own doc comment) so this
    /// can never wedge true for the rest of the session.
    private func updateWorkFlag() {
        lock.lock()
        let hasPendingWork = !bufferedAudio.isEmpty || recognitionInFlight
        lock.unlock()
        coachingCoordinator.updateTranscriptionWork(hasPendingWork)
    }

    // MARK: - Receive

    /// Normalizes a received frame to the JSON object `handle` expects, regardless of which
    /// `URLSessionWebSocketTask.Message` case carried it, so there is exactly one parse-and-dispatch
    /// path for the two frame kinds.
    ///
    /// WIRE FACT — do not "simplify" this back to `.string`-only: Gemini's `BidiGenerateContent`
    /// endpoint sends every server response, including the `setupComplete` handshake acknowledgement,
    /// as a BINARY frame, not TEXT. That was verified against the live server with an independent
    /// client; dropping the `.data` branch silently discards every frame again and readiness never
    /// fires. A `.data` frame carries the same UTF-8 JSON text a `.string` frame would.
    func handle(_ message: URLSessionWebSocketTask.Message, on lease: WebSocketConnection.Lease) {
        let text: String
        let kind: String
        switch message {
        case .string(let value):
            text = value
            kind = "string"
        case .data(let bytes):
            guard let decoded = String(data: bytes, encoding: .utf8) else {
                // Never log frame contents — a transcript is user speech. Kind and length only.
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
            // Never log frame contents — a transcript is user speech. Kind and length only.
            jlog("Jarvis Gemini [\(speaker.rawValue)]: dropped unparsable \(kind) frame "
                 + "(\(text.utf8.count) bytes)")
            return
        }
        handleFrame(obj, on: lease)
    }

    /// One received frame. Order matters: a setup acknowledgement must be seen before any transcript
    /// is trusted. There is no in-frame terminal-error branch here — the Live API's
    /// `BidiGenerateContentServerMessage` has no `error` frame (see `GeminiLiveSession`'s close-code
    /// doc comment); the WebSocket close code handled in `urlSession(_:webSocketTask:didCloseWith:)`
    /// is the only terminal-failure signal Gemini sends. `goAway` is the one other server-initiated
    /// lifecycle frame besides `setupComplete` — advance warning of an approaching close, not a
    /// failure; see `beginDrain`.
    private func handleFrame(_ message: [String: Any], on lease: WebSocketConnection.Lease) {
        // Re-validate the lease even though the connection already did: the UTF-8 and JSON parsing
        // above sits between that check and this one, and the socket can be replaced during it (a
        // failure path bumps the generation and opens a new task). Acting on a stale frame here is
        // not cosmetic: a stale frame could mutate `recognitionInFlight` or admit pre-reconnect
        // transcript text. `isCurrent` subsumes a plain `stopped` check by also requiring task
        // identity and generation; do not "simplify" it back to a `stopped` test.
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
            // Clear here — on the raw frame, NOT inside the `if let text` below — because Gemini has
            // definitively finished recognizing this utterance the moment ANY finalized
            // `inputTranscription` arrives, even one whose text `TranscriptFiltering` goes on to
            // reject (e.g. a "Thank you." hallucinated on silence — exactly the case
            // `hallucinationDenylist` exists for). Clearing only inside the filtered branch left
            // `recognitionInFlight` wedged true after a rejected final, gating automatic coaching on
            // a signal that had already resolved. A filtered final still means the server is done.
            lock.lock(); recognitionInFlight = false; let isDraining = draining; lock.unlock()
            if let text = GeminiLiveSession.finalTranscript(from: message, speaker: speaker) {
                continuityReporter.recordServerSpeech(
                    .transcriptionCompleted, audioTimeMilliseconds: nil,
                    socketGeneration: lease.generation)
                // Gemini reports no per-utterance start time, so `spokenAt: nil` lets the coordinator
                // date the line from the session clock. `source` is debug-only detail, never Activity.
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
            // A filtered-out final still needs the work flag re-evaluated: it may be all that was
            // holding the turn open (see `updateWorkFlag`'s doc comment).
            updateWorkFlag()
            if isDraining {
                // The utterance the grace period existed for just finished — no reason to wait out
                // the rest of it. Rotate now instead of on `armDrainDeadline`'s timer.
                rotateNow(lease, reason: "utterance finalized during drain")
            }
            return
        }
        if GeminiLiveSession.hasInterimTranscription(message) {
            // Gemini is actively recognizing speech right now. Read only the boolean signal — never
            // the interim text itself, which is speculative and revised mid-utterance; it must never
            // reach Activity or the transcript (see the ActivityLog contract in AGENTS.md). This is
            // what keeps the coordinator's turn open past the moment the last chunk finishes sending,
            // until Gemini actually finishes recognizing it — see `updateWorkFlag`.
            lock.lock(); recognitionInFlight = true; lock.unlock()
            updateWorkFlag()
            return
        }
        if GeminiLiveSession.isVoiceActivityStart(message) {
            // Gemini's voice-activity detector just started hearing speech — the earliest local signal
            // that recognition is in flight, ahead of the first interim frame for the same utterance
            // (see `recognitionInFlight`'s doc comment for the measured gap and why both signals are
            // kept). This frame carries no transcript text of any kind, so nothing here can leak speech
            // to Activity. Read only the boolean; never log the frame body.
            lock.lock(); recognitionInFlight = true; lock.unlock()
            updateWorkFlag()
            return
        }
        // Unknown frames are diagnostic only — never Activity, never the transcript. See the
        // ActivityLog contract in AGENTS.md.
        jlog("Jarvis Gemini [\(speaker.rawValue)]: frame ignored "
             + "(\(message.keys.sorted().joined(separator: ",")))")
    }

    // MARK: - Drain / rotate (goAway)

    /// Google caps a Live API connection at roughly 10 minutes and sends `goAway` shortly before
    /// closing it (https://ai.google.dev/gemini-api/docs/live-api/session-management) — advance
    /// warning, not a failure. Left unhandled, both speaker sockets (opened together, so they expire
    /// together) would simply drop mid-utterance: the final transcript in flight at that moment would
    /// be lost, and its buffered audio would replay from the middle on the replacement — a garbled
    /// line roughly every 10 minutes.
    ///
    /// This starts the drain: mark `draining` so `pumpIfPossible` stops sending NEW audio to this
    /// socket (it keeps accumulating in the existing bounded `bufferedAudio` FIFO, with no second
    /// buffer), tell the connection to expect the rotation so the close it produces is read as that
    /// rather than a fault, then arm a bounded grace period for the utterance already in flight to
    /// produce its final on this still-open socket before the replacement takes over. `!draining` in
    /// the guard makes this idempotent against a resent `goAway` for the same socket.
    private func beginDrain(_ lease: WebSocketConnection.Lease, timeLeft: TimeInterval?) {
        lock.lock()
        // `isReady`, not `isCurrent`: a `goAway` before `setupComplete` describes a socket that
        // never worked, and the connection refuses to rotate one of those for free. Draining it
        // would only stall audio until the readiness deadline retired it anyway.
        let leaseIsCurrent = !stopped && !draining && connection.isReady(lease)
        // Only wait if there is actually an utterance to wait FOR. A drain armed with nothing in
        // flight stalls new audio for the whole grace period to protect a final that is never
        // coming: measured over a 62-minute live session, all six rotations took exactly the full
        // 5s and every one reported "grace period elapsed", because no speech was in flight at any
        // goAway. That is up to 5s of buffered-instead-of-streamed audio every ~9 minutes on both
        // sockets, delaying the transcript and the coaching gated on it, for no benefit.
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

    /// Bounds the drain with the same main-queue-confined, double-checked timer discipline as
    /// `armReadyTimeout`/`sendHealthPing`'s pong timer: an outer main-queue hop re-validates the lease
    /// before arming, and the timer body re-validates again before acting, so a lease that changed in
    /// between (e.g. an early rotation from the final arriving, or a Stop) leaves it a no-op.
    ///
    /// The bound is `goAwayGraceTimeout` unless the server's own `timeLeft` is smaller, in which case
    /// that takes precedence — waiting past the server's stated deadline would just trade a
    /// self-inflicted timeout for the same lost-final problem this exists to avoid. This is the
    /// mandatory backstop: if the final never arrives (a lost frame, or the server closing early),
    /// rotation proceeds anyway. An unbounded drain would hang the stream — strictly worse than the
    /// garbled line being fixed.
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

    /// Whether `lease` is still the socket this transcriber is draining. Both the outer main-queue
    /// hop and the timer body re-check it, so a lease that changed in between (an early rotation from
    /// the final arriving, or a Stop) leaves the deadline a no-op.
    private func isDraining(_ lease: WebSocketConnection.Lease) -> Bool {
        lock.lock(); let isDraining = draining && !stopped; lock.unlock()
        return isDraining && connection.isCurrent(lease)
    }

    /// Deliberately replace a socket Google already warned is closing, ahead of the actual close,
    /// rather than reconnecting reactively. Two callers converge here: the drain deadline elapsing
    /// and the in-flight utterance's final arriving early. A transport failure that lands on a
    /// still-draining socket takes the same route, through the connection's own check that the
    /// rotation was already expected.
    ///
    /// None of them spend retry budget: a rotation Google told us about in advance is expected
    /// transport churn, not a fault, so it must not consume what a genuine failure needs and must
    /// never report `.failed`. The connection bumps the generation for the replacement (so a late
    /// callback from the old socket is rejected exactly as a normal reconnect rejects one) and calls
    /// `connectionWillOpen`, which clears `recognitionInFlight` (correct here too, since whatever
    /// the expiring socket was still recognizing is unknowable) and `draining`, so a failure of the
    /// fresh socket is never mistaken for still-expected drain churn.
    private func rotateNow(_ lease: WebSocketConnection.Lease, reason: String) {
        guard isDraining(lease) else { return }
        connection.requestRotation(lease, reason: reason)
    }

    /// This transcriber's identity in every failure it classifies.
    private var source: ProviderFailure.Source { .transcription(.gemini) }
}
