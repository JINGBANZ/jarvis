import Foundation
import JarvisCore

/// Live transcription over the Gemini Live socket. Mirrors `RealtimeTranscriber`'s lifecycle —
/// setup-acknowledged readiness, backoff reconnect, ping/pong liveness, bounded offline buffering —
/// but carries no ledger or commit path: Gemini finalizes each utterance server-side, so there are
/// no out-of-order items to reconcile and no client-managed turn boundaries to track.
///
/// SECURITY: Gemini authenticates with a query parameter (`GeminiLiveSession.connectURL(apiKey:)`),
/// so the API key lives in the connect URL. Nothing in this file may log, interpolate, or stringify
/// that URL, a `URLRequest` built from it, or a raw transport `Error` — `URLError` and
/// `URLSessionWebSocketTask` failures can embed the failing URL in their `description`. Every
/// diagnostic that names the endpoint uses `GeminiLiveSession.redactedEndpoint`, and every transport
/// failure path constructs its own fixed reason string instead of interpolating the caught error.
///
/// `@unchecked Sendable`: every mutable field is guarded by `lock`; timer creation/invalidation is
/// dispatched to the main queue; `coachingCoordinator` and `continuityReporter` guard their own state
/// and are themselves Sendable.
final class GeminiLiveTranscriber: NSObject, TranscriptionSession, URLSessionWebSocketDelegate,
    @unchecked Sendable {
    var onTurnEnd: (@Sendable (_ transcriptBoundary: Int) -> Void)?
    var onSilence: (@Sendable (TimeInterval) -> Void)?
    var onTranscriptionWorkChanged: (@Sendable (Bool) -> Void)?
    var onConnectionStateChange: (@Sendable (TranscriptionConnectionState) -> Void)?
    var onTerminalFailure: (@Sendable (TranscriptionFailureReason) -> Void)?
    var onCaptureHeartbeat: (@Sendable (CaptureHeartbeat) -> Void)?

    private let reconnectSchedule = RetrySchedule(
        maximumRetries: 6, initialDelay: 1, maximumDelay: 30)
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
    private let readyTimeout: TimeInterval
    private let pingInterval: TimeInterval
    private let pongTimeout: TimeInterval
    private let networkStatus: @Sendable () -> String
    /// `nil` for every normal coaching session. Optional chaining then skips event construction.
    private let benchmark: TranscriptionBenchmarkInstrumentation?
    private var coachingCoordinator: TranscriptionCoachingCoordinator!
    private let continuityReporter: RealtimeContinuityReporter

    private let lock = NSLock()
    private var apiKey: String            // guarded by lock; used on the NEXT connect only
    private var session: URLSession?      // retained so stop() can invalidate it (URLSession holds its delegate)
    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var readyTimer: Timer?
    private var pongTimer: Timer?
    /// Audio captured while disconnected, or not yet accepted by the live socket. Plain byte-capped
    /// FIFO: unlike `RealtimeTranscriber`'s `PCMBuffer`, there is no server audio-clock acknowledgement
    /// to correlate against, so a chunk simply leaves this queue once its send completes.
    private var bufferedAudio: [Data] = []
    private var bufferedByteCount = 0
    private var isSending = false         // one in-flight audio send at a time, preserves order
    private var reconnectAttempt = 0
    private var isReconnecting = false
    private var stopped = true
    private var connected = false         // true only once the server acknowledges setup
    private var terminalFailureReported = false
    private var generation = 0            // rejects late callbacks from a replaced socket
    private var pendingPingGeneration: Int?

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
        networkStatus: @escaping @Sendable () -> String = { "unavailable" },
        activity: (any ActivityEventRecording)? = nil,
        benchmark: TranscriptionBenchmarkInstrumentation? = nil
    ) {
        self.apiKey = apiKey
        self.model = model
        self.expectedLanguages = TranscriptionLanguage.canonicalizing(expectedLanguages)
        self.vocabularyKeywords = vocabularyKeywords
        self.mode = mode
        self.audioFormat = audioFormat
        self.speaker = speaker
        self.clock = clock
        self.sessionStart = sessionStart
        self.maxBufferedAudioSeconds = maxBufferedAudioSeconds
        self.readyTimeout = readyTimeout
        self.pingInterval = pingInterval
        self.pongTimeout = pongTimeout
        self.networkStatus = networkStatus
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
        super.init()
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
        stopped = false; reconnectAttempt = 0; isReconnecting = false
        terminalFailureReported = false
        lock.unlock()
        coachingCoordinator.start()
        emitState(.connecting)
        openSocket()
        continuityReporter.start()
    }

    /// Keep a healthy socket in place; the replacement credential is picked up if this side later
    /// reconnects. This avoids destroying live transcript state merely because Settings saved a key.
    func updateAPIKey(_ apiKey: String) {
        lock.lock()
        self.apiKey = apiKey
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopped = true; connected = false
        let pt = pingTimer; pingTimer = nil
        let rt = readyTimer; readyTimer = nil
        let pot = pongTimer; pongTimer = nil
        let t = task; task = nil
        let s = session; session = nil
        pendingPingGeneration = nil
        isSending = false
        generation += 1                 // invalidate every callback retained by the old task
        bufferedAudio.removeAll(keepingCapacity: false)
        bufferedByteCount = 0
        lock.unlock()
        // Timers must be invalidated on the thread that scheduled them (main); doing it synchronously
        // from an off-main Stop would silently fail to cancel and could let a stray timer fire later.
        DispatchQueue.main.async {
            pt?.invalidate(); rt?.invalidate(); pot?.invalidate()
        }
        continuityReporter.stop()
        coachingCoordinator.stop()
        if let t {
            // Best-effort: tell Gemini no more audio is coming so it can finalize the last utterance.
            // Fire-and-forget — Stop must not block on network I/O, and the socket is cancelled
            // immediately after regardless of whether this frame lands.
            if let data = try? JSONSerialization.data(withJSONObject: GeminiLiveSession.audioStreamEnd()),
               let text = String(data: data, encoding: .utf8) {
                t.send(.string(text)) { _ in }
            }
            t.cancel(with: .normalClosure, reason: nil)
        }
        s?.invalidateAndCancel()
        emitState(.stopped)
    }

    // MARK: - Socket lifecycle

    private func openSocket() {
        lock.lock(); let currentKey = apiKey; lock.unlock()
        // NEVER log `request`, its `.url`, or anything derived from `connectURL` — the key travels in
        // the query string. `GeminiLiveSession.redactedEndpoint` is the only safe diagnostic form.
        let request = URLRequest(url: GeminiLiveSession.connectURL(apiKey: currentKey))
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        lock.lock()
        let previousSession = self.session
        generation += 1
        let socketGeneration = generation
        self.session = session
        self.task = task
        isReconnecting = false; connected = false; isSending = false; pendingPingGeneration = nil
        lock.unlock()
        previousSession?.invalidateAndCancel()   // release the previous session's delegate retain
        invalidateConnectionTimers()
        jlog(
            "Jarvis Gemini [\(speaker.rawValue)]: opening socket #\(socketGeneration) "
                + "endpoint=\(GeminiLiveSession.redactedEndpoint) model=\(model.rawValue) "
                + "expected-languages="
                + (expectedLanguages.isEmpty
                    ? "automatic"
                    : expectedLanguages.map(\.rawValue).joined(separator: ",")))
        task.resume()
        sendSetupMessage(task: task, socketGeneration: socketGeneration)
        receiveLoop(task: task, generation: socketGeneration)
        armReadyTimeout(task: task, generation: socketGeneration)
    }

    private func sendSetupMessage(task: URLSessionWebSocketTask, socketGeneration: Int) {
        let setup = GeminiLiveSession.setupMessage(
            model: model, languages: expectedLanguages, vocabulary: vocabularyKeywords, mode: mode)
        guard let data = try? JSONSerialization.data(withJSONObject: setup),
              let text = String(data: data, encoding: .utf8) else {
            failConnection(task: task, generation: socketGeneration,
                           diagnostic: "could not encode Gemini setup message")
            return
        }
        task.send(.string(text)) { [weak self, weak task] error in
            guard let self, let task else { return }
            guard error != nil else { return }
            // Never log the caught error — a `URLError` can embed the connect URL (and its key) in
            // its description. A fixed, self-authored reason is the only safe diagnostic here.
            self.failConnection(task: task, generation: socketGeneration,
                                diagnostic: "setup send failed")
        }
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
        bufferedAudio.append(pcm)
        bufferedByteCount += pcm.count
        var evicted = 0
        while audioFormat.duration(forByteCount: bufferedByteCount) > maxBufferedAudioSeconds,
              !bufferedAudio.isEmpty {
            bufferedByteCount -= bufferedAudio.removeFirst().count
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
        var activeTask: URLSessionWebSocketTask?
        var socketGeneration = 0
        lock.lock()
        if let task, connected, !stopped, !isReconnecting, !isSending,
           let first = bufferedAudio.first {
            frame = first
            activeTask = task
            socketGeneration = generation
            isSending = true
        }
        lock.unlock()
        guard let frame, let activeTask else { return }
        sendFrame(frame, task: activeTask, socketGeneration: socketGeneration)
    }

    private func sendFrame(_ pcm: Data, task: URLSessionWebSocketTask, socketGeneration: Int) {
        let frame = GeminiLiveSession.audioFrame(
            base64PCM: pcm.base64EncodedString(), sampleRate: audioFormat.sampleRate)
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8) else {
            // A local encoding bug, not a transport fault — drop this one chunk and keep going
            // rather than tearing down an otherwise healthy socket.
            lock.lock()
            if !bufferedAudio.isEmpty { bufferedByteCount -= bufferedAudio.removeFirst().count }
            isSending = false
            lock.unlock()
            updateWorkFlag()
            pumpIfPossible()
            return
        }
        task.send(.string(text)) { [weak self, weak task] error in
            guard let self, let task else { return }
            if error != nil {
                // Never log the caught error — see the security note atop this file.
                self.lock.lock(); self.isSending = false; self.lock.unlock()
                self.failConnection(task: task, generation: socketGeneration,
                                    diagnostic: "audio send failed")
                return
            }
            self.lock.lock()
            let isCurrentLease = self.task === task && self.generation == socketGeneration
                && self.connected && !self.stopped && !self.isReconnecting
            if isCurrentLease, let first = self.bufferedAudio.first, first == pcm {
                self.bufferedByteCount -= self.bufferedAudio.removeFirst().count
            }
            self.isSending = false
            self.lock.unlock()
            self.updateWorkFlag()
            self.pumpIfPossible()
        }
    }

    /// `true` while buffered audio has not yet been accepted by a live socket — the coordinator holds
    /// a turn open until this settles, since Gemini's transcript for that audio is still in flight.
    private func updateWorkFlag() {
        lock.lock(); let hasPendingWork = !bufferedAudio.isEmpty; lock.unlock()
        coachingCoordinator.updateTranscriptionWork(hasPendingWork)
    }

    // MARK: - Receive

    private func receiveLoop(task: URLSessionWebSocketTask, generation socketGeneration: Int) {
        task.receive { [weak self, weak task] result in
            guard let self, let task else { return }
            guard self.isCurrent(task: task, generation: socketGeneration) else { return }
            switch result {
            case .failure:
                // A failed pending receive is the EXPECTED artifact of an intentional Stop (cancel).
                // Never log the caught error — see the security note atop this file.
                self.lock.lock(); let isStopped = self.stopped; self.lock.unlock()
                if isStopped { return }
                self.failConnection(task: task, generation: socketGeneration,
                                    diagnostic: "receive failed")
            case .success(let message):
                self.decodeAndHandle(message, task: task, generation: socketGeneration)
                self.receiveLoop(task: task, generation: socketGeneration)
            }
        }
    }

    /// Normalizes a received frame to the JSON object `handle` expects, regardless of which
    /// `URLSessionWebSocketTask.Message` case carried it, so there is exactly one parse-and-dispatch
    /// path for the two frame kinds.
    ///
    /// WIRE FACT — do not "simplify" this back to `.string`-only: Gemini's `BidiGenerateContent`
    /// endpoint sends every server response, including the `setupComplete` handshake acknowledgement,
    /// as a BINARY frame, not TEXT. That was verified against the live server with an independent
    /// client; dropping the `.data` branch silently discards every frame again and readiness never
    /// fires. A `.data` frame carries the same UTF-8 JSON text a `.string` frame would.
    private func decodeAndHandle(_ message: URLSessionWebSocketTask.Message,
                                 task: URLSessionWebSocketTask, generation socketGeneration: Int) {
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
        handle(obj, task: task, generation: socketGeneration)
    }

    /// One received frame. Order matters: a terminal error outranks everything, and a setup
    /// acknowledgement must be seen before any transcript is trusted.
    private func handle(_ message: [String: Any], task: URLSessionWebSocketTask,
                        generation socketGeneration: Int) {
        lock.lock(); let isStopped = stopped; lock.unlock()
        if isStopped { return }
        if let failure = GeminiLiveSession.terminalFailure(from: message) {
            reportTerminalFailureOnce(failure)
            return
        }
        if GeminiLiveSession.isSetupComplete(message) {
            markReady(task: task, generation: socketGeneration)
            return
        }
        if let text = GeminiLiveSession.finalTranscript(from: message, speaker: speaker) {
            continuityReporter.recordServerSpeech(
                .transcriptionCompleted, audioTimeMilliseconds: nil,
                socketGeneration: socketGeneration)
            // Gemini reports no per-utterance start time, so `spokenAt: nil` lets the coordinator
            // date the line from the session clock. `source` is debug-only detail, never Activity.
            let accepted = coachingCoordinator.recordFinalizedTranscript(
                text, spokenAt: nil, source: "gemini-live")
            benchmark?.observer.record(.init(
                kind: .finalized,
                provider: TranscriptionProvider.gemini.rawValue,
                model: model.rawValue,
                speaker: speaker.rawValue,
                generation: socketGeneration,
                text: text,
                observedAt: clock.now(),
                transcriptUnavailable: !accepted))
            return
        }
        // Interim hypotheses and unknown frames are diagnostic only — never Activity, never the
        // transcript. See the ActivityLog contract in AGENTS.md.
        jlog("Jarvis Gemini [\(speaker.rawValue)]: frame ignored "
             + "(\(message.keys.sorted().joined(separator: ",")))")
    }

    private func markReady(task: URLSessionWebSocketTask, generation socketGeneration: Int) {
        lock.lock()
        guard let currentTask = self.task, currentTask === task, generation == socketGeneration,
              !connected, !stopped, !isReconnecting else { lock.unlock(); return }
        connected = true; reconnectAttempt = 0
        lock.unlock()
        invalidateReadyTimer(task: task, generation: socketGeneration)
        jlog("Jarvis Gemini [\(speaker.rawValue)]: transcription session ready "
             + "(socket #\(socketGeneration))")
        benchmark?.observer.record(.init(
            kind: .ready,
            provider: TranscriptionProvider.gemini.rawValue,
            model: model.rawValue,
            speaker: speaker.rawValue,
            generation: socketGeneration,
            observedAt: clock.now()))
        updateWorkFlag()
        pumpIfPossible()
        emitState(.ready)
        startPing(task: task, generation: socketGeneration)
    }

    /// End a green-but-unusable transcription session immediately for permanent provider failures.
    private func reportTerminalFailureOnce(_ reason: TranscriptionFailureReason) {
        lock.lock()
        guard !stopped, !terminalFailureReported else { lock.unlock(); return }
        terminalFailureReported = true
        connected = false
        lock.unlock()
        invalidateConnectionTimers()
        emitState(.failed)
        jlog("Jarvis Gemini [\(speaker.rawValue)]: unrecoverable transcription failure — stopping")
        onTerminalFailure?(reason)
    }

    // MARK: - Reconnect / keepalive

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.lock()
        guard let currentTask = task, currentTask === webSocketTask else { lock.unlock(); return }
        let socketGeneration = generation
        let isStopped = stopped
        lock.unlock()
        if isStopped { return } // An intentional Stop closes the socket on purpose.
        failConnection(task: webSocketTask, generation: socketGeneration,
                      diagnostic: "socket closed: code \(closeCode.rawValue)")
    }

    /// Move the current socket into reconnect exactly once. Every failure source (receive, close,
    /// send, readiness deadline, and pong deadline) funnels through here; `generation` prevents a late
    /// callback from an old socket from disrupting its healthy replacement.
    private func failConnection(task failedTask: URLSessionWebSocketTask, generation failedGeneration: Int,
                                diagnostic: String?) {
        lock.lock()
        guard let currentTask = task else { lock.unlock(); return }
        if stopped || terminalFailureReported || isReconnecting
            || generation != failedGeneration || currentTask !== failedTask {
            lock.unlock(); return
        }
        connected = false; isSending = false
        pendingPingGeneration = nil
        let failedSession = session
        task = nil
        session = nil
        guard let retryDelay = reconnectSchedule.delay(forRetry: reconnectAttempt) else {
            isReconnecting = true
            terminalFailureReported = true
            lock.unlock()
            if let diagnostic { logTransportFailure(diagnostic, generation: failedGeneration) }
            invalidateConnectionTimers()
            failedTask.cancel(with: .goingAway, reason: nil)
            failedSession?.invalidateAndCancel()
            emitState(.failed)
            jlog("Jarvis Gemini [\(speaker.rawValue)]: giving up after "
                 + "\(reconnectSchedule.maximumRetries) reconnect attempts — stopping")
            onTerminalFailure?(.connectionLost)
            return
        }
        isReconnecting = true
        let attempt = reconnectAttempt
        reconnectAttempt = attempt + 1
        lock.unlock()

        if let diagnostic { logTransportFailure(diagnostic, generation: failedGeneration) }
        invalidateConnectionTimers()
        failedTask.cancel(with: .goingAway, reason: nil)
        failedSession?.invalidateAndCancel()
        emitState(.reconnecting(attempt: attempt + 1))
        updateWorkFlag() // any still-buffered audio is now definitely unsent work

        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let shouldReconnect = !self.stopped && self.generation == failedGeneration
                && self.task == nil && self.isReconnecting
            self.lock.unlock()
            guard shouldReconnect else { return }
            jlog("Jarvis Gemini [\(self.speaker.rawValue)]: reconnecting (attempt \(attempt + 1))")
            self.openSocket()
        }
    }

    // DIVERGENCE HAZARD: The ready-timeout, ping-pong, timer invalidation, and generation-guard logic
    // below is mirrored in RealtimeTranscriber.swift. A fix made here almost certainly belongs there too.
    // Extracting a shared lifecycle helper is a separate, focused change; do not refactor here.
    private func armReadyTimeout(task: URLSessionWebSocketTask, generation socketGeneration: Int) {
        DispatchQueue.main.async { [weak self, weak task] in
            guard let self, let task else { return }
            self.lock.lock()
            let isPending = self.task === task && self.generation == socketGeneration
                && !self.connected && !self.isReconnecting && !self.stopped
            self.lock.unlock()
            guard isPending else { return }
            self.readyTimer?.invalidate()
            self.readyTimer = Timer.scheduledTimer(withTimeInterval: self.readyTimeout, repeats: false) {
                [weak self, weak task] _ in
                guard let self, let task else { return }
                self.lock.lock()
                let isStillPending = self.task === task && self.generation == socketGeneration
                    && !self.connected && !self.isReconnecting && !self.stopped
                self.lock.unlock()
                guard isStillPending else { return }
                self.failConnection(task: task, generation: socketGeneration,
                                    diagnostic: "session readiness timed out after \(self.readyTimeout)s")
            }
        }
    }

    private func startPing(task: URLSessionWebSocketTask, generation socketGeneration: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let isReady = self.task === task && self.generation == socketGeneration
                && self.connected && !self.isReconnecting && !self.stopped
            self.lock.unlock()
            guard isReady else { return }
            self.pingTimer?.invalidate()
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: self.pingInterval, repeats: true) {
                [weak self, weak task] _ in
                guard let self, let task else { return }
                self.sendHealthPing(task: task, generation: socketGeneration)
            }
        }
    }

    private func sendHealthPing(task: URLSessionWebSocketTask, generation socketGeneration: Int) {
        lock.lock()
        guard let currentTask = self.task, currentTask === task,
              generation == socketGeneration, connected,
              pendingPingGeneration == nil else { lock.unlock(); return }
        pendingPingGeneration = socketGeneration
        lock.unlock()

        DispatchQueue.main.async { [weak self, weak task] in
            guard let self, let task else { return }
            self.pongTimer?.invalidate()
            self.pongTimer = Timer.scheduledTimer(withTimeInterval: self.pongTimeout, repeats: false) {
                [weak self, weak task] _ in
                guard let self, let task else { return }
                self.lock.lock()
                let isStillPending = self.task === task && self.generation == socketGeneration
                    && self.pendingPingGeneration == socketGeneration && self.connected
                    && !self.isReconnecting && !self.stopped
                self.lock.unlock()
                guard isStillPending else { return }
                self.failConnection(task: task, generation: socketGeneration,
                                    diagnostic: "pong timed out after \(self.pongTimeout)s")
            }
        }

        task.sendPing { [weak self, weak task] error in
            guard let self, let task else { return }
            if error != nil {
                // Never log the caught error — see the security note atop this file.
                self.failConnection(task: task, generation: socketGeneration,
                                    diagnostic: "ping failed")
                return
            }
            self.lock.lock()
            guard let currentTask = self.task, currentTask === task,
                  self.generation == socketGeneration else {
                self.lock.unlock(); return
            }
            self.pendingPingGeneration = nil
            self.lock.unlock()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let isSameSocket = self.task === task && self.generation == socketGeneration
                self.lock.unlock()
                guard isSameSocket else { return }
                self.pongTimer?.invalidate()
                self.pongTimer = nil
            }
        }
    }

    private func isCurrent(task candidate: URLSessionWebSocketTask, generation candidateGeneration: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let currentTask = task else { return false }
        return !stopped && !isReconnecting
            && currentTask === candidate && generation == candidateGeneration
    }

    private func invalidateReadyTimer(task: URLSessionWebSocketTask, generation socketGeneration: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let isSameSocket = self.task === task && self.generation == socketGeneration
            self.lock.unlock()
            guard isSameSocket else { return }
            self.readyTimer?.invalidate()
            self.readyTimer = nil
        }
    }

    private func invalidateConnectionTimers() {
        DispatchQueue.main.async { [weak self] in
            self?.readyTimer?.invalidate(); self?.readyTimer = nil
            self?.pingTimer?.invalidate(); self?.pingTimer = nil
            self?.pongTimer?.invalidate(); self?.pongTimer = nil
        }
    }

    private func logTransportFailure(_ diagnostic: String, generation socketGeneration: Int) {
        jlog("Jarvis Gemini [\(speaker.rawValue)] socket #\(socketGeneration) \(diagnostic) "
             + "(network: \(networkStatus()))")
    }

    private func emitState(_ state: TranscriptionConnectionState) {
        onConnectionStateChange?(state)
    }
}
