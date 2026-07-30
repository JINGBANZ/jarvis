import Foundation
import JarvisCore

/// Client for the OpenAI GA Realtime API used as a **transcription session**. Streams PCM16 audio,
/// configures server-VAD turn detection, and parses transcription + speech events — adding lines to
/// the RollingTranscript and firing turn/silence events.
///
/// The wire contract (connect URL with `?intent=transcription`, the `session.update` payload, the
/// audio-append event) is built by the pure, unit-tested `RealtimeSession` in JarvisCore. The
/// transcription model is `gpt-4o-transcribe`, which supports `server_vad` so the server
/// auto-commits the audio buffer per utterance and emits `…transcription.completed` — no manual
/// `input_audio_buffer.commit` is required.
///
/// Robustness: waits for the server's configuration acknowledgement before reporting ready, probes
/// ready sockets with ping/pong, and reconnects with capped exponential backoff on every detected
/// send, receive, close, startup-timeout, or liveness failure.
final class RealtimeTranscriber: NSObject, TranscriptionSession, URLSessionWebSocketDelegate,
    @unchecked Sendable {
    var onTurnEnd: (@Sendable () -> Void)?
    var onSilence: (@Sendable (TimeInterval) -> Void)?
    var onSpeechActivityChanged: (@Sendable (Bool) -> Void)?
    var onConnectionStateChange: (@Sendable (TranscriptionConnectionState) -> Void)?
    /// Fired when transcription becomes unusable, either from an unrecoverable provider rejection or
    /// after reconnection is abandoned, so the app can stop instead of lying green.
    var onTerminalFailure: (@Sendable (TranscriptionFailureReason) -> Void)?

    private let reconnectSchedule = RetrySchedule(
        maximumRetries: 6, initialDelay: 1, maximumDelay: 30)
    private var apiKey: String
    private let model: String
    /// Who this socket is transcribing: `.me` (mic) or `.them` (system audio). Two transcribers run
    /// in parallel — one per side — feeding the same `RollingTranscript`, so the coach sees both.
    private let speaker: Speaker
    private let transcript: RollingTranscript
    private let clock: Clock
    private let sessionStart: TimeInterval
    private let silenceDurationMs: Int
    private let noiseReduction: NoiseReductionMode
    private let readyTimeout: TimeInterval
    private let pingInterval: TimeInterval
    private let pongTimeout: TimeInterval
    private let networkStatus: @Sendable () -> String

    private let lock = NSLock()
    private var session: URLSession?     // retained so stop() can invalidate it (URLSession holds its delegate)
    private var task: URLSessionWebSocketTask?
    private var silenceTimer: Timer?
    /// Backs off the proactive silence-check interval across a long quiet stretch. Mutated only on
    /// the main queue (where the silence timer is scheduled and fires), so it needs no extra lock.
    private var silenceBackoff: SilenceBackoff
    /// Whether the idle-cutoff pause has been logged for the current quiet stretch (log it once, not
    /// on every dormant re-check). Main-queue only, like `silenceBackoff`.
    private var silencePausedLogged = false
    private var pingTimer: Timer?
    private var readyTimer: Timer?
    private var pongTimer: Timer?
    private var transcriptionLifecycle: RealtimeTranscriptionLifecycle!
    private let continuityReporter: RealtimeContinuityReporter
    private let audioBuffer: PCMBuffer        // mic audio captured while the socket is down
    private var reconnectAttempt = 0
    private var isReconnecting = false
    private var stopped = false
    private var connected = false        // true only between "session ready" and the next drop/close
    private var everConnected = false    // distinguishes the first connect from a reconnect
    private var rotating = false         // an EXPECTED server rotation is mid-flight; quiet the noise it makes
    private var terminalFailureReported = false
    private var generation = 0           // rejects late callbacks from a replaced socket
    private var pendingPingGeneration: Int?
    /// Realtime's `audio_start_ms` is relative to audio written on one socket. These origins map it
    /// back onto Jarvis's overall session clock, including audio buffered during reconnect backoff.
    private var pendingAudioTimelineOrigin: TimeInterval = 0
    private var activeAudioTimelineOrigin: TimeInterval = 0

    init(apiKey: String, model: String, speaker: Speaker = .me, transcript: RollingTranscript, clock: Clock,
         silenceTimeout: TimeInterval, silenceMaxInterval: TimeInterval,
         silenceIdleCutoff: TimeInterval = .infinity,
         silenceDurationMs: Int = 1000, noiseReduction: NoiseReductionMode = .auto,
         turnDebounce: TimeInterval = 0.4, transcriptionTerminalTimeout: TimeInterval = 8,
         transcriptionActiveTimeout: TimeInterval = 180,
         maxBufferedAudioSeconds: TimeInterval = 60,
         readyTimeout: TimeInterval = 10, pingInterval: TimeInterval = 20,
         pongTimeout: TimeInterval = 10,
         networkStatus: @escaping @Sendable () -> String = { "unavailable" }) {
        self.apiKey = apiKey
        self.model = model
        self.speaker = speaker
        self.transcript = transcript
        self.clock = clock
        let sessionStart = clock.now()
        self.sessionStart = sessionStart
        self.silenceBackoff = SilenceBackoff(base: silenceTimeout, maxInterval: silenceMaxInterval,
                                             idleCutoff: silenceIdleCutoff)
        self.silenceDurationMs = silenceDurationMs
        self.noiseReduction = noiseReduction
        self.readyTimeout = readyTimeout
        self.pingInterval = pingInterval
        self.pongTimeout = pongTimeout
        self.networkStatus = networkStatus
        // PCM16 mono at the realtime sample rate → 2 bytes/sample.
        let bytesPerSecond = RealtimeSession.sampleRate * 2
        self.audioBuffer = PCMBuffer(maxBytes: Int(maxBufferedAudioSeconds) * bytesPerSecond)
        self.continuityReporter = RealtimeContinuityReporter(
            speaker: speaker, clock: clock, sessionStart: sessionStart)
        super.init()
        self.transcriptionLifecycle = RealtimeTranscriptionLifecycle(
            speaker: speaker, transcript: transcript, clock: clock, sessionStart: sessionStart,
            turnDebounce: turnDebounce, terminalTimeout: transcriptionTerminalTimeout,
            activeTimeout: transcriptionActiveTimeout,
            isCurrentGeneration: { [weak self] generation in
                self?.isLive(socketGeneration: generation) == true
            },
            isReady: { [weak self] generation in self?.isReady(socketGeneration: generation) == true },
            discardConfirmedAudio: { [weak self] boundary in
                _ = self?.audioBuffer.discardSent(through: boundary)
            },
            resetSilenceTimer: { [weak self] in self?.resetSilenceTimer() },
            onTurnEnd: { [weak self] in self?.onTurnEnd?() },
            onSpeechActivityChanged: { [weak self] active in
                self?.onSpeechActivityChanged?(active)
            })
    }

    func connect() {
        // Start clean: clear the stopped flag AND any stale backoff state from a prior session.
        lock.lock()
        stopped = false; reconnectAttempt = 0; isReconnecting = false; rotating = false
        terminalFailureReported = false
        pendingAudioTimelineOrigin = 0; activeAudioTimelineOrigin = 0
        lock.unlock()
        transcriptionLifecycle.start()
        emitState(.connecting)
        openSocket()
        // Arm the proactive silence check exactly once, here on the first connect. A reconnect (session
        // rotation) re-enters via openSocket() directly, NOT connect(), so the running timer is left
        // alone — its backoff step and elapsed quiet carry across the rotation instead of snapping back
        // to the base interval every ~hour. (Speech still resets it, via `handle`.)
        resetSilenceTimer()
        continuityReporter.start()
    }

    /// Keep a healthy socket in place; the replacement credential is picked up if this side later
    /// reconnects. This avoids destroying live transcript state merely because Settings saved a key.
    func updateAPIKey(_ apiKey: String) {
        lock.lock()
        self.apiKey = apiKey
        lock.unlock()
    }

    private func openSocket() {
        var req = URLRequest(url: RealtimeSession.connectURL())
        lock.lock()
        let apiKey = self.apiKey
        lock.unlock()
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: req)
        lock.lock()
        let previousSession = self.session
        generation += 1
        let socketGeneration = generation
        self.session = session
        self.task = task; isReconnecting = false; connected = false; pendingPingGeneration = nil
        lock.unlock()
        previousSession?.invalidateAndCancel()   // release the previous session's delegate retain
        invalidateConnectionTimers()
        jlog("Jarvis realtime [\(speaker.rawValue)]: opening socket #\(socketGeneration)")
        task.resume()
        configureSession()
        receiveLoop(task: task, generation: socketGeneration)
        armReadyTimeout(task: task, generation: socketGeneration)
    }

    func stop() {
        lock.lock()
        stopped = true; connected = false
        let st = silenceTimer; silenceTimer = nil
        let pt = pingTimer; pingTimer = nil
        let rt = readyTimer; readyTimer = nil
        let pot = pongTimer; pongTimer = nil
        let t = task; task = nil
        let s = session; session = nil
        pendingPingGeneration = nil
        generation += 1                 // invalidate every callback retained by the old task
        audioBuffer.clear()             // atomic with `stopped`: no producer can append after this
        lock.unlock()
        // Timers must be invalidated on the thread that scheduled them (main); doing it synchronously
        // from an off-main Stop (e.g. the onTerminalFailure Task) would silently fail to cancel and
        // could let a stray timer fire onSilence on a torn-down pipeline.
        DispatchQueue.main.async {
            st?.invalidate(); pt?.invalidate(); rt?.invalidate(); pot?.invalidate()
        }
        continuityReporter.stop()
        transcriptionLifecycle.stop()
        // A user-initiated Stop is a normal closure (1000), not "going away" (1001).
        t?.cancel(with: .normalClosure, reason: nil)
        s?.invalidateAndCancel()             // breaks the URLSession→delegate(self)→closures→driver retain chain
        emitState(.stopped)
    }

    private func configureSession() {
        // Resolve .auto against the live default-input device each session, so a reconnect after a
        // device swap (e.g. plugging in AirPods) picks the right profile.
        let profile = NoiseReduction.profile(mode: noiseReduction, micProximity: InputDeviceProximity.current())
        send(json: RealtimeSession.sessionUpdate(model: model, silenceDurationMs: silenceDurationMs,
                                                 noiseReduction: profile))
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
        // Every chunk enters one ordered FIFO. Local send completion moves it into a bounded recovery
        // tail rather than deleting it: Realtime does not acknowledge append events, so only later
        // server audio-clock progress can retire that prefix safely.
        let observedAt = clock.now() - sessionStart
        let sessionRelativeCaptureAt = capturedAt - sessionStart
        let duration = TimeInterval(pcm.count) / TimeInterval(RealtimeSession.sampleRate * 2)
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        let evicted = audioBuffer.append(pcm, sequenceNumber: sequenceNumber,
                                         capturedAt: sessionRelativeCaptureAt,
                                         duration: duration)
        lock.unlock()
        continuityReporter.recordDelivery(sequence: sequenceNumber, pcm16: pcm, at: observedAt)
        reportBufferEviction(evicted)
        pumpAudioIfReady()
    }

    private func reportBufferEviction(_ evicted: [PCMBuffer.Chunk]) {
        guard !evicted.isEmpty else { return }
        transcriptionLifecycle.recordReplayCoverageLoss()
        continuityReporter.recordBufferEviction(evicted)
    }

    private func pumpAudioIfReady() {
        lock.lock()
        guard let task, connected, !stopped, !isReconnecting,
              let claim = audioBuffer.claimNext() else { lock.unlock(); return }
        let socketGeneration = generation
        lock.unlock()
        sendAudioClaim(claim, task: task, socketGeneration: socketGeneration)
    }

    @discardableResult
    private func send(json: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let str = String(data: data, encoding: .utf8) else { return false }
        lock.lock(); let t = task; let socketGeneration = generation; lock.unlock()
        guard let t else { return false }
        t.send(.string(str)) { [weak self, weak t] error in
            guard let self, let t else { return }
            guard let error else { return }
            self.failConnection(task: t, generation: socketGeneration,
                                diagnostic: "send failed: \(error)")
        }
        return true
    }

    private func sendAudioClaim(_ claim: PCMBuffer.Claim, task: URLSessionWebSocketTask,
                                socketGeneration: Int) {
        guard let sequence = claim.chunk.sequenceNumber,
              let data = try? JSONSerialization.data(withJSONObject: RealtimeSession.appendAudio(
                base64PCM: claim.chunk.data.base64EncodedString())),
              let text = String(data: data, encoding: .utf8) else {
            _ = audioBuffer.retry(claim)
            return
        }
        continuityReporter.recordSendAttempt(
            sequence: sequence, socketGeneration: socketGeneration)
        task.send(.string(text)) { [weak self, weak task] error in
            guard let self, let task else { return }
            if let error {
                self.continuityReporter.recordSendFailure(
                    sequence: sequence, socketGeneration: socketGeneration)
                // Disconnect first. Its state transition releases the current FIFO claim while no
                // producer can select this failed socket; retrying before that transition would let
                // a racing producer send the same head on the dead task.
                self.failConnection(task: task, generation: socketGeneration,
                                    diagnostic: "send failed: \(error)")
                return
            }
            self.continuityReporter.recordSendSuccess(
                sequence: sequence, socketGeneration: socketGeneration)
            self.lock.lock()
            let isCurrentLease = self.task === task && self.generation == socketGeneration
                && self.connected && !self.stopped && !self.isReconnecting
            let completion = isCurrentLease ? self.audioBuffer.completeSend(claim) : nil
            self.lock.unlock()
            if let completion {
                self.reportBufferEviction(completion.evicted)
                self.pumpAudioIfReady()
            }
        }
    }

    private func receiveLoop(task: URLSessionWebSocketTask, generation socketGeneration: Int) {
        task.receive { [weak self, weak task] result in
            guard let task else { return }
            guard let self else { return }
            guard self.isCurrent(task: task, generation: socketGeneration) else { return }
            switch result {
            case .failure(let err):
                // A failed pending receive is the EXPECTED artifact of an intentional Stop
                // (cancel → ENOTCONN/POSIX 57). Suppress it then; only a live failure reconnects.
                self.lock.lock(); let isStopped = self.stopped; let quiet = self.rotating; self.lock.unlock()
                if isStopped { return }
                // During an expected rotation the failing receive is just the old socket going away — the
                // rotation line already covers it, so don't surface "Socket is not connected" on top.
                self.failConnection(task: task, generation: socketGeneration,
                                    diagnostic: quiet ? nil : "receive failed: \(err)")
            case .success(let message):
                if case .string(let text) = message {
                    self.handle(text, task: task, generation: socketGeneration)
                }
                self.receiveLoop(task: task, generation: socketGeneration)
            }
        }
    }

    private func handle(_ text: String, task: URLSessionWebSocketTask, generation socketGeneration: Int) {
        // A buffered message can still arrive after an intentional Stop; don't mutate the transcript
        // or log on a torn-down pipeline (mirrors the failure/close-path gates).
        lock.lock(); let isStopped = stopped; lock.unlock()
        if isStopped { return }
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        if RealtimeSession.isConfiguredSessionEventType(type) {
            let sessionID = (obj["session"] as? [String: Any])?["id"] as? String
            markReady(task: task, generation: socketGeneration, sessionID: sessionID)
            return
        }

        switch type {
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
            // whole), but DON'T fire the coach yet — debounce so rapid fragments of one spoken
            // sentence coalesces into a single trigger. `audio_start_ms`, captured by the ledger on
            // speech_started, timestamps the line when it was spoken rather than when inference ended.
            guard let itemID = obj["item_id"] as? String else {
                jlog("Jarvis realtime [\(speaker.rawValue)]: completed transcription missing item_id")
                break
            }
            let transcriptText = obj["transcript"] as? String ?? ""
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
            let terminalFailure = RealtimeSession.terminalTranscriptionFailure(from: obj)
            continuityReporter.recordServerSpeech(.transcriptionFailed,
                                   audioTimeMilliseconds: nil,
                                   itemID: itemID,
                                   socketGeneration: socketGeneration)
            transcriptionLifecycle.recordFailed(
                itemID: itemID, error: error, socketGeneration: socketGeneration)
            if let terminalFailure { reportTerminalFailure(terminalFailure) }
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
            _ = transcriptionLifecycle.recordSpeechStopped(
                itemID: itemID, audioEndMilliseconds: audioEndMilliseconds,
                socketGeneration: socketGeneration)
            // Do not reset proactive silence here. Bare VAD start/stop events contain no usable
            // context; only an appended final/salvaged line begins a fresh silence interval.
        case "session.created", "transcription_session.created":
            // The WebSocket handshake succeeded, but our transcription configuration has not yet
            // been acknowledged. Stay in `connecting` and keep buffering until the updated event.
            break
        case "error":
            // A session_expired error is the server telling us this session hit its lifetime cap. That's
            // an expected rotation, not a fault: announce it once, calmly, and mark `rotating` so the
            // close / receive-failure it triggers next don't pile on scary lines. The reconnect itself is
            // driven by those paths as usual. Any OTHER error is a real fault — log it verbatim.
            if RealtimeSession.isSessionExpired(obj) {
                noteRotation("reached its time limit")
                failConnection(task: task, generation: socketGeneration, diagnostic: nil)
            } else {
                jlog("Jarvis realtime [\(speaker.rawValue)] error event: \(text)")
                if let terminalFailure = RealtimeSession.terminalTranscriptionFailure(from: obj) {
                    reportTerminalFailure(terminalFailure)
                }
            }
        default:
            break
        }
    }

    private func markReady(task: URLSessionWebSocketTask, generation socketGeneration: Int,
                           sessionID: String?) {
        lock.lock()
        guard let currentTask = self.task, currentTask === task,
              generation == socketGeneration, !connected, !stopped, !isReconnecting else {
            lock.unlock(); return
        }
        let wasReconnect = everConnected
        everConnected = true; rotating = false; reconnectAttempt = 0
        activeAudioTimelineOrigin = audioBuffer.oldestQueuedCaptureTime
            ?? pendingAudioTimelineOrigin
        let bufferedChunks = audioBuffer.queuedChunkCount
        // Keep old-socket deltas throughout reconnect attempts so terminal failure can still salvage
        // them. Once a replacement is ready, its replayed PCM becomes authoritative and old item IDs
        // must leave before the replacement emits its own lifecycle events.
        connected = true
        lock.unlock()
        let recovery = wasReconnect
            ? transcriptionLifecycle.markReplacementReady(socketGeneration: socketGeneration)
            : nil
        invalidateReadyTimer(task: task, generation: socketGeneration)
        let id = sessionID.map { ", session \($0)" } ?? ""
        jlog("Jarvis realtime [\(speaker.rawValue)]: transcription session ready (socket #\(socketGeneration)\(id))")
        if wasReconnect && bufferedChunks > 0 {
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
        // Producers always append to the same claimed FIFO. Making readiness visible before this
        // pump is safe: a racing producer may claim the oldest chunk itself, but cannot bypass it or
        // strand the chunk it just appended.
        pumpAudioIfReady()
        emitState(.ready)
        startPing(task: task, generation: socketGeneration)
    }

    private func isReady(socketGeneration: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == socketGeneration && connected && !isReconnecting && !stopped
    }

    private func isLive(socketGeneration: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == socketGeneration && task != nil && !isReconnecting && !stopped
    }

    private static func transcriptionErrorDescription(from event: [String: Any]) -> String {
        guard let error = event["error"] as? [String: Any] else { return "unknown error" }
        let code = error["code"] as? String
        let message = error["message"] as? String
        let description = [code, message].compactMap { $0 }.joined(separator: ": ")
        return description.isEmpty ? "unknown error" : description
    }

    /// End a green-but-unusable transcription session immediately for permanent provider failures.
    /// The Activity layer receives only the typed reason; the raw provider detail was logged by the
    /// item lifecycle immediately before this call.
    private func reportTerminalFailure(_ reason: TranscriptionFailureReason) {
        lock.lock()
        guard !stopped, !terminalFailureReported else { lock.unlock(); return }
        terminalFailureReported = true
        connected = false
        lock.unlock()
        invalidateConnectionTimers()
        emitState(.failed)
        jlog("Jarvis realtime [\(speaker.rawValue)]: unrecoverable transcription failure — stopping")
        onTerminalFailure?(reason)
    }

    // MARK: - Reconnect / keepalive

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.lock()
        guard let currentTask = task, currentTask === webSocketTask else { lock.unlock(); return }
        let socketGeneration = generation
        let isStopped = stopped
        let quiet = rotating
        lock.unlock()
        if isStopped { return } // An intentional Stop closes the socket on purpose.
        // A server "going away" (1001) is a routine rotation/restart we just reconnect through. Treat it
        // as expected even if no session_expired error preceded it (the two can arrive in either order);
        // any other close code is unexpected and stays visible.
        if closeCode == .goingAway { noteRotation("server going away") }
        let diagnostic = quiet ? nil : "socket closed: code \(closeCode.rawValue)"
        failConnection(task: webSocketTask, generation: socketGeneration, diagnostic: diagnostic)
    }

    /// Announce an expected server-initiated rotation exactly once, then mark `rotating` so the close /
    /// receive-failure it produces stay quiet until the replacement session is ready (which clears it).
    private func noteRotation(_ reason: String) {
        lock.lock(); let already = rotating; rotating = true; lock.unlock()
        if !already {
            jlog("Jarvis realtime [\(speaker.rawValue)]: session rotating (\(reason)) — reconnecting")
        }
    }

    /// Move the current socket into reconnect exactly once. Every failure source (receive, close,
    /// send, readiness deadline, and pong deadline) funnels through here; `generation` prevents a late
    /// callback from an old socket from disrupting its healthy replacement.
    private func failConnection(task failedTask: URLSessionWebSocketTask, generation failedGeneration: Int,
                                diagnostic: String?) {
        let failureAt = clock.now() - sessionStart
        lock.lock()
        guard let currentTask = task else { lock.unlock(); return }
        if stopped || terminalFailureReported || isReconnecting
            || generation != failedGeneration || currentTask !== failedTask {
            lock.unlock(); return
        }
        connected = false
        pendingPingGeneration = nil
        let failedSession = session
        // Remove the failed task immediately. A receive callback can pass `isCurrent` just before
        // this failure wins the lock; `markReady` checks the installed task again, so clearing it
        // prevents a late session acknowledgement from resetting backoff or draining buffered audio
        // into the canceled socket during the reconnect delay.
        task = nil
        session = nil
        guard let retryDelay = reconnectSchedule.delay(forRetry: reconnectAttempt) else {
            isReconnecting = true
            terminalFailureReported = true
            lock.unlock()
            audioBuffer.retryInFlight()
            transcriptionLifecycle.finalizeInterrupted(reason: "socket failure")
            if let diagnostic { logTransportFailure(diagnostic, generation: failedGeneration) }
            invalidateConnectionTimers()
            failedTask.cancel(with: .goingAway, reason: nil)
            failedSession?.invalidateAndCancel()
            emitState(.failed)
            jlog("Jarvis realtime [\(speaker.rawValue)]: giving up after "
                 + "\(reconnectSchedule.maximumRetries) reconnect attempts — stopping")
            onTerminalFailure?(.connectionLost)
            return
        }
        isReconnecting = true
        let attempt = reconnectAttempt
        reconnectAttempt = attempt + 1
        // Local WebSocket send completions are not server acknowledgements. Requeue the entire
        // unconfirmed tail now, while producers are excluded by this lock, so audio sent during a
        // half-open interval precedes audio captured during reconnect backoff.
        let replay = audioBuffer.prepareForReconnect()
        pendingAudioTimelineOrigin = replay.oldestCapturedAt ?? failureAt
        lock.unlock()

        let interruptedItems = transcriptionLifecycle.beginReconnectRecovery(
            replayAvailable: audioBuffer.bufferedChunkCount > 0)
        reportBufferEviction(replay.evicted)
        // Old-socket deltas are now held by the reconnect recovery gate. They remain a fallback if
        // every handshake fails or bounded replay loses coverage, without keeping stale item IDs in
        // the replacement ledger or releasing a partial coaching turn early.
        if interruptedItems > 0 && attempt == 0 {
            jlog("Jarvis realtime [\(speaker.rawValue)] retaining \(interruptedItems) interrupted "
                 + "transcription item(s) until replacement replay is ready")
        }
        if replay.replayedChunks > 0 {
            jlog("Jarvis realtime [\(speaker.rawValue)] retained \(replay.replayedChunks) "
                 + "locally-sent audio chunks for end-to-end reconnect replay")
        }
        if let diagnostic { logTransportFailure(diagnostic, generation: failedGeneration) }
        invalidateConnectionTimers()
        failedTask.cancel(with: .goingAway, reason: nil)
        failedSession?.invalidateAndCancel()
        emitState(.reconnecting(attempt: attempt + 1))

        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let shouldReconnect = !self.stopped && self.generation == failedGeneration
            self.lock.unlock()
            guard shouldReconnect else { return }
            jlog("Jarvis realtime [\(self.speaker.rawValue)]: reconnecting (attempt \(attempt + 1))")
            self.openSocket()
        }
    }

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
            if let error {
                self.failConnection(task: task, generation: socketGeneration,
                                    diagnostic: "ping failed: \(error)")
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
        jlog("Jarvis realtime [\(speaker.rawValue)] socket #\(socketGeneration) \(diagnostic) "
             + "(network: \(networkStatus()))")
    }

    private func emitState(_ state: TranscriptionConnectionState) {
        onConnectionStateChange?(state)
    }

    /// (Re)start the proactive silence check from its base interval — called from `connect()` (the first
    /// connect) and whenever usable speech is appended, so a fresh quiet stretch always begins at the
    /// base interval before backing off. A reconnect re-enters via `openSocket()` and deliberately does
    /// NOT call this, so a session rotation preserves the current backoff step rather than resetting it.
    private func resetSilenceTimer() {
        // The "them" transcriber leaves onSilence nil (only the mic owns the "are you stuck?" prompt);
        // skip arming a timer that would just no-op, avoiding per-utterance main-queue/Timer churn.
        guard onSilence != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.silenceBackoff.reset()
            self.silencePausedLogged = false
            self.armSilenceTimer()
        }
    }

    /// Schedule the next "maybe stuck" silence check using the current backoff interval. When it fires
    /// (no speech in the meantime) it reports how long the user has been quiet, then re-arms with the
    /// next, longer interval — so a long silence is gently re-checked (the interval doubles each step
    /// up to a cap; see `Config`) rather than nudged once and never again. Must be called on the main queue.
    private func armSilenceTimer() {
        let interval = silenceBackoff.next()
        scheduleSilenceTimer(after: interval, quietThreshold: interval)
    }

    /// Keep a due silence check pending while a transcription item is unresolved. This short local
    /// recheck does not advance or reset backoff: a VAD noise/start event contains no usable context
    /// and must not buy another full 120-second interval. A finalized line resets the real timer.
    private func scheduleSilenceTimer(after delay: TimeInterval, quietThreshold interval: TimeInterval) {
        lock.lock(); silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.silenceTimerDidFire(quietThreshold: interval)
        }
        lock.unlock()
    }

    private func silenceTimerDidFire(quietThreshold interval: TimeInterval) {
        lock.lock(); let isStopped = stopped; lock.unlock()
        guard !isStopped else { return }   // don't drive a coaching turn on a torn-down pipeline
        if transcriptionLifecycle.hasUnsettledItems {
            scheduleSilenceTimer(after: 1, quietThreshold: interval)
            return
        }
        let quiet = transcript.silenceDuration(now: clock.now() - sessionStart)
        // Only nudge on GENUINE conversational silence. The transcript is shared with the "them"
        // (system-audio) socket, so `quiet` reflects the last line from EITHER side. If the other
        // party spoke within this interval the user isn't stuck — they're listening — so suppress
        // the nudge and restart the backoff, so a fresh quiet stretch begins at the base interval
        // once the conversation actually goes quiet. (Mic speech resets via resetSilenceTimer; this
        // covers the them side, which only feeds the shared transcript and doesn't reset the timer.)
        guard quiet >= interval else {
            silenceBackoff.reset()
            silencePausedLogged = false
            armSilenceTimer()
            return
        }
        // Idle cutoff, enforced at FIRE time (a timer scheduled just under the cutoff must not
        // bill one last probe past it). Past the cutoff the user has stepped away, so suppress
        // the probe but keep this (free, local) check chain alive: it is the only path that can
        // revive probing on "them" speech — that side only feeds the shared transcript, and the
        // guard above then resets the backoff. Mic speech revives via resetSilenceTimer as usual.
        if silenceBackoff.shouldProbe(quietSoFar: quiet) {
            silencePausedLogged = false
            onSilence?(quiet)
        } else if !silencePausedLogged {
            silencePausedLogged = true   // log the pause once, not every capped interval
            jlog("🤫 quiet for \(Int(quiet))s — pausing silence checks until speech resumes")
        }
        armSilenceTimer()             // re-arm with the next (backed-off) interval
    }
}
