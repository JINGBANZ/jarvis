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
/// Robustness: reconnects with capped exponential backoff on socket failure/close, and sends a
/// periodic ping keepalive so idle NAT/proxy timeouts don't silently kill transcription.
final class RealtimeTranscriber: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var onTurnEnd: (@Sendable () -> Void)?
    var onSilence: (@Sendable (TimeInterval) -> Void)?
    /// Fired when reconnection is abandoned after `maxReconnects` consecutive failures (e.g. a bad
    /// key / quota), so the app can flip the menu back to ⚪️ stopped instead of lying green.
    var onTerminalFailure: (@Sendable () -> Void)?

    private let maxReconnects = 6
    private let apiKey: String
    private let model: String
    /// Who this socket is transcribing: `.me` (mic) or `.them` (system audio). Two transcribers run
    /// in parallel — one per side — feeding the same `RollingTranscript`, so the coach sees both.
    private let speaker: Speaker
    private let transcript: RollingTranscript
    private let clock: Clock
    private let sessionStart: TimeInterval
    private let silenceDurationMs: Int
    private let noiseReduction: NoiseReductionMode
    private let turnDebounce: TimeInterval

    private let lock = NSLock()
    private var session: URLSession?     // retained so stop() can invalidate it (URLSession holds its delegate)
    private var task: URLSessionWebSocketTask?
    private var silenceTimer: Timer?
    /// Backs off the proactive silence-check interval across a long quiet stretch. Mutated only on
    /// the main queue (where the silence timer is scheduled and fires), so it needs no extra lock.
    private var silenceBackoff: SilenceBackoff
    private var pingTimer: Timer?
    private var debounceTimer: Timer?         // coalesces rapid fragments into one trigger
    private let pending = UtteranceBuffer()   // fragments heard since the last fired trigger
    private let audioBuffer: PCMBuffer        // mic audio captured while the socket is down
    private var reconnectAttempt = 0
    private var isReconnecting = false
    private var stopped = false
    private var connected = false        // true only between "session ready" and the next drop/close
    private var everConnected = false    // distinguishes the first connect from a reconnect
    private var rotating = false         // an EXPECTED server rotation is mid-flight; quiet the noise it makes

    init(apiKey: String, model: String, speaker: Speaker = .me, transcript: RollingTranscript, clock: Clock,
         silenceTimeout: TimeInterval, silenceMaxInterval: TimeInterval,
         silenceDurationMs: Int = 1000, noiseReduction: NoiseReductionMode = .auto,
         turnDebounce: TimeInterval = 0.4, maxBufferedAudioSeconds: TimeInterval = 60) {
        self.apiKey = apiKey
        self.model = model
        self.speaker = speaker
        self.transcript = transcript
        self.clock = clock
        self.sessionStart = clock.now()
        self.silenceBackoff = SilenceBackoff(base: silenceTimeout, maxInterval: silenceMaxInterval)
        self.silenceDurationMs = silenceDurationMs
        self.noiseReduction = noiseReduction
        self.turnDebounce = turnDebounce
        // PCM16 mono at the realtime sample rate → 2 bytes/sample.
        let bytesPerSecond = RealtimeSession.sampleRate * 2
        self.audioBuffer = PCMBuffer(maxBytes: Int(maxBufferedAudioSeconds) * bytesPerSecond)
        super.init()
    }

    func connect() {
        // Start clean: clear the stopped flag AND any stale backoff state from a prior session.
        lock.lock(); stopped = false; reconnectAttempt = 0; isReconnecting = false; rotating = false; lock.unlock()
        openSocket()
    }

    private func openSocket() {
        var req = URLRequest(url: RealtimeSession.connectURL())
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: req)
        lock.lock()
        self.session?.invalidateAndCancel()   // release the previous session's delegate retain
        self.session = session
        self.task = task; isReconnecting = false; connected = false
        lock.unlock()
        task.resume()
        configureSession()
        receiveLoop()
        // Arm the proactive silence check on the FIRST connect only. On a reconnect (session rotation)
        // the existing timer keeps running — it's tied to the conversation, not the socket — so the
        // backoff step and the elapsed quiet carry across the rotation instead of snapping back to the
        // base interval every time the ~hourly session rotates. (Speech still resets it, via `handle`.)
        lock.lock(); let firstConnect = !everConnected; lock.unlock()
        if firstConnect { resetSilenceTimer() }
        startPing()
    }

    func stop() {
        lock.lock()
        stopped = true; connected = false
        let st = silenceTimer; silenceTimer = nil
        let pt = pingTimer; pingTimer = nil
        let db = debounceTimer; debounceTimer = nil
        let t = task; task = nil
        let s = session; session = nil
        lock.unlock()
        // Timers must be invalidated on the thread that scheduled them (main); doing it synchronously
        // from an off-main Stop (e.g. the onTerminalFailure Task) would silently fail to cancel and
        // could let a stray timer fire onSilence on a torn-down pipeline.
        DispatchQueue.main.async { st?.invalidate(); pt?.invalidate(); db?.invalidate() }
        pending.clear()
        audioBuffer.clear()   // a user Stop discards buffered audio; don't replay it on a later Start
        // A user-initiated Stop is a normal closure (1000), not "going away" (1001).
        t?.cancel(with: .normalClosure, reason: nil)
        s?.invalidateAndCancel()             // breaks the URLSession→delegate(self)→closures→driver retain chain
    }

    private func configureSession() {
        // Resolve .auto against the live default-input device each session, so a reconnect after a
        // device swap (e.g. plugging in AirPods) picks the right profile.
        let profile = NoiseReduction.profile(mode: noiseReduction, micProximity: InputDeviceProximity.current())
        send(json: RealtimeSession.sessionUpdate(model: model, silenceDurationMs: silenceDurationMs,
                                                 noiseReduction: profile))
    }

    func sendAudio(_ pcm: Data) {
        // Audio streams continuously from the mic tap. While the socket is down (between a drop and
        // the reconnect's "session ready"), BUFFER it instead of discarding, so a mid-sentence drop
        // doesn't lose the user's words — it's flushed into the new session on reconnect. We still
        // never log a failed send, so the disconnect stays quiet.
        lock.lock(); let isConnected = connected; let isStopped = stopped; lock.unlock()
        if isStopped { return }
        if isConnected {
            send(json: RealtimeSession.appendAudio(base64PCM: pcm.base64EncodedString()))
        } else {
            audioBuffer.append(pcm)
        }
    }

    /// Replay any audio captured while disconnected into the freshly-ready session, then resume live.
    /// On the FIRST connect this is just the brief connect-handshake gap, so it's flushed silently;
    /// only a true reconnect logs the replay (the first-start "replayed … after reconnect" line was
    /// misleading).
    private func flushBufferedAudio(isReconnect: Bool) {
        // Drain-and-send in a loop while `connected` is still false (so live mic audio keeps buffering
        // and can't be sent ahead of these older chunks). Each pass catches audio that arrived during
        // the previous send; a small cap prevents spinning if the mic streams continuously.
        var total = 0
        for _ in 0..<8 {
            let chunks = audioBuffer.drain()
            if chunks.isEmpty { break }
            total += chunks.count
            for chunk in chunks {
                send(json: RealtimeSession.appendAudio(base64PCM: chunk.base64EncodedString()))
            }
        }
        if isReconnect && total > 0 { jlog("⏩ replayed \(total) buffered audio chunks after reconnect") }
    }

    private func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let str = String(data: data, encoding: .utf8) else { return }
        lock.lock(); let t = task; lock.unlock()
        // Don't log send failures: they're non-actionable and arrive in bulk on a drop; the
        // receive/close paths are what detect the disconnect and drive reconnect.
        t?.send(.string(str)) { _ in }
    }

    private func receiveLoop() {
        lock.lock(); let t = task; lock.unlock()
        t?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                // A failed pending receive is the EXPECTED artifact of an intentional Stop
                // (cancel → ENOTCONN/POSIX 57). Suppress it then; only a live failure reconnects.
                self.lock.lock(); let isStopped = self.stopped; let quiet = self.rotating; self.connected = false; self.lock.unlock()
                if isStopped { return }
                // During an expected rotation the failing receive is just the old socket going away — the
                // rotation line already covers it, so don't surface "Socket is not connected" on top.
                if !quiet { jlog("Jarvis realtime receive failed: \(err)") }
                self.scheduleReconnect()
            case .success(let message):
                self.lock.lock(); self.reconnectAttempt = 0; self.lock.unlock() // healthy
                if case .string(let text) = message { self.handle(text) }
                self.receiveLoop()
            }
        }
    }

    private func handle(_ text: String) {
        // A buffered message can still arrive after an intentional Stop; don't mutate the transcript
        // or log on a torn-down pipeline (mirrors the failure/close-path gates).
        lock.lock(); let isStopped = stopped; lock.unlock()
        if isStopped { return }
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case RealtimeSession.completedTranscriptionType:
            // A completed utterance fragment: record it immediately (so the model's context is
            // whole), but DON'T fire the coach yet — debounce so rapid fragments of one spoken
            // sentence coalesce into a single trigger. The wire→text parse lives in RealtimeSession
            // (pure + unit-tested).
            if let transcriptText = RealtimeSession.completedTranscript(from: obj, speaker: speaker) {
                let at = clock.now() - sessionStart
                transcript.append(.init(speaker: speaker, text: transcriptText, at: at))
                jlog("🗣 heard (\(speaker.rawValue)): \"\(transcriptText)\"")   // show side + what was said
                pending.append(transcriptText)
                resetSilenceTimer()
                scheduleTurnDebounce()
            }
        case "input_audio_buffer.speech_stopped":
            // Server VAD detected end of speech; the actionable turn-end (with transcript) is
            // handled on the completed event above. Just refresh the silence timer here.
            resetSilenceTimer()
        case "session.created", "transcription_session.created":
            // A fresh session is up: the rotation (if any) completed, so re-enable normal drop logging.
            lock.lock(); let wasReconnect = everConnected; everConnected = true; rotating = false; lock.unlock()
            jlog("Jarvis realtime: transcription session ready")
            // Flush buffered audio BEFORE marking connected, so live mic audio (which keeps buffering
            // while !connected) can't be sent ahead of the older buffered chunks and scramble order.
            flushBufferedAudio(isReconnect: wasReconnect)
            lock.lock(); connected = true; lock.unlock()
        case "error":
            // A session_expired error is the server telling us this session hit its lifetime cap. That's
            // an expected rotation, not a fault: announce it once, calmly, and mark `rotating` so the
            // close / receive-failure it triggers next don't pile on scary lines. The reconnect itself is
            // driven by those paths as usual. Any OTHER error is a real fault — log it verbatim.
            if RealtimeSession.isSessionExpired(obj) { noteRotation("reached its time limit") }
            else { jlog("Jarvis realtime error event: \(text)") }
        default:
            break
        }
    }

    /// Coalesce rapid completed-fragments: (re)start a short timer on each fragment; when it settles
    /// we fire ONE turn-end trigger for the whole utterance. This fixes residual VAD fragmentation so
    /// one spoken sentence drives one brain turn, not several.
    private func scheduleTurnDebounce() {
        let window = turnDebounce
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.stopped else { return }   // a block queued before stop() must not re-arm a timer
            self.debounceTimer?.invalidate()
            self.debounceTimer = Timer.scheduledTimer(withTimeInterval: window, repeats: false) { [weak self] _ in
                self?.fireTurn()
            }
        }
    }

    private func fireTurn() {
        lock.lock()
        if stopped { lock.unlock(); return }
        debounceTimer?.invalidate(); debounceTimer = nil
        lock.unlock()
        let (_, fragments) = pending.flush()

        if fragments > 1 {
            // VAD diagnostic: if this is frequently > 1, the silence window is still too short.
            jlog("🧩 coalesced \(fragments) fragments into one turn")
        }

        onTurnEnd?()
    }

    // MARK: - Reconnect / keepalive

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        // An intentional Stop closes the socket on purpose; don't alarm the user with it.
        lock.lock(); let isStopped = stopped; let quiet = rotating; connected = false; lock.unlock()
        if isStopped { return }
        // A server "going away" (1001) is a routine rotation/restart we just reconnect through. Treat it
        // as expected even if no session_expired error preceded it (the two can arrive in either order);
        // any other close code is unexpected and stays visible.
        if closeCode == .goingAway { noteRotation("server going away") }
        else if !quiet { jlog("Jarvis realtime socket closed: code \(closeCode.rawValue)") }
        scheduleReconnect()
    }

    /// Announce an expected server-initiated rotation exactly once, then mark `rotating` so the close /
    /// receive-failure it produces stay quiet until the replacement session is ready (which clears it).
    private func noteRotation(_ reason: String) {
        lock.lock(); let already = rotating; rotating = true; lock.unlock()
        if !already { jlog("Jarvis realtime: session rotating (\(reason)) — reconnecting") }
    }

    private func scheduleReconnect() {
        lock.lock()
        if stopped || isReconnecting { lock.unlock(); return }
        if reconnectAttempt >= maxReconnects {
            lock.unlock()
            jlog("Jarvis realtime: giving up after \(maxReconnects) reconnect attempts — stopping")
            onTerminalFailure?()
            return
        }
        isReconnecting = true
        let attempt = reconnectAttempt
        reconnectAttempt = attempt + 1
        lock.unlock()

        let delay = min(30.0, pow(2.0, Double(attempt)))   // 1, 2, 4, 8, 16, 30…
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let stop = self.stopped; self.lock.unlock()
            guard !stop else { return }
            jlog("Jarvis realtime: reconnecting (attempt \(attempt + 1))")
            self.openSocket()
        }
    }

    private func startPing() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.pingTimer?.invalidate()
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); let t = self.task; let isConnected = self.connected; self.lock.unlock()
                guard isConnected else { return }   // no keepalive on a dropped/reconnecting socket
                t?.sendPing { _ in }                // a failed ping is handled by the receive/close path
            }
            self.lock.unlock()
        }
    }

    /// (Re)start the proactive silence check from its base interval — called on the first connect and
    /// whenever speech is heard, so a fresh quiet stretch always begins at the base interval before
    /// backing off. A reconnect deliberately does NOT call this (see `openSocket`), so a session
    /// rotation preserves the current backoff step rather than resetting it.
    private func resetSilenceTimer() {
        // The "them" transcriber leaves onSilence nil (only the mic owns the "are you stuck?" prompt);
        // skip arming a timer that would just no-op, avoiding per-utterance main-queue/Timer churn.
        guard onSilence != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.silenceBackoff.reset()
            self.armSilenceTimer()
        }
    }

    /// Schedule the next "maybe stuck" silence check using the current backoff interval. When it fires
    /// (no speech in the meantime) it reports how long the user has been quiet, then re-arms with the
    /// next, longer interval — so a long silence is gently re-checked (the interval doubles each step
    /// up to a cap; see `Config`) rather than nudged once and never again. Must be called on the main queue.
    private func armSilenceTimer() {
        let interval = silenceBackoff.next()
        lock.lock(); silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); let isStopped = self.stopped; self.lock.unlock()
            guard !isStopped else { return }   // don't drive a coaching turn on a torn-down pipeline
            let quiet = self.transcript.silenceDuration(now: self.clock.now() - self.sessionStart)
            // Only nudge on GENUINE conversational silence. The transcript is shared with the "them"
            // (system-audio) socket, so `quiet` reflects the last line from EITHER side. If the other
            // party spoke within this interval the user isn't stuck — they're listening — so suppress
            // the nudge and restart the backoff, so a fresh quiet stretch begins at the base interval
            // once the conversation actually goes quiet. (Mic speech resets via resetSilenceTimer; this
            // covers the them side, which only feeds the shared transcript and doesn't reset the timer.)
            guard quiet >= interval else {
                self.silenceBackoff.reset()
                self.armSilenceTimer()
                return
            }
            self.onSilence?(quiet)
            self.armSilenceTimer()             // re-arm with the next (backed-off) interval
        }
        lock.unlock()
    }
}
