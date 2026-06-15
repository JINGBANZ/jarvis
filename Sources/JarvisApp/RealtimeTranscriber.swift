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
    /// Fired when the just-finished utterance addressed Jarvis by name — the coach must reply.
    var onDirectAddress: (@Sendable () -> Void)?
    /// Fired when reconnection is abandoned after `maxReconnects` consecutive failures (e.g. a bad
    /// key / quota), so the app can flip the menu back to ⚪️ stopped instead of lying green.
    var onTerminalFailure: (@Sendable () -> Void)?

    private let maxReconnects = 6
    private let apiKey: String
    private let model: String
    private let transcript: RollingTranscript
    private let clock: Clock
    private let sessionStart: TimeInterval
    private let silenceTimeout: TimeInterval
    private let silenceDurationMs: Int
    private let turnDebounce: TimeInterval

    private let lock = NSLock()
    private var session: URLSession?     // retained so stop() can invalidate it (URLSession holds its delegate)
    private var task: URLSessionWebSocketTask?
    private var silenceTimer: Timer?
    private var pingTimer: Timer?
    private var debounceTimer: Timer?         // coalesces rapid fragments into one trigger
    private let pending = UtteranceBuffer()   // fragments heard since the last fired trigger
    private var reconnectAttempt = 0
    private var isReconnecting = false
    private var stopped = false
    private var connected = false        // true only between "session ready" and the next drop/close

    init(apiKey: String, model: String, transcript: RollingTranscript, clock: Clock,
         silenceTimeout: TimeInterval = 8, silenceDurationMs: Int = 1000,
         turnDebounce: TimeInterval = 0.4) {
        self.apiKey = apiKey
        self.model = model
        self.transcript = transcript
        self.clock = clock
        self.sessionStart = clock.now()
        self.silenceTimeout = silenceTimeout
        self.silenceDurationMs = silenceDurationMs
        self.turnDebounce = turnDebounce
        super.init()
    }

    func connect() {
        // Start clean: clear the stopped flag AND any stale backoff state from a prior session.
        lock.lock(); stopped = false; reconnectAttempt = 0; isReconnecting = false; lock.unlock()
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
        resetSilenceTimer()
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
        // A user-initiated Stop is a normal closure (1000), not "going away" (1001).
        t?.cancel(with: .normalClosure, reason: nil)
        s?.invalidateAndCancel()             // breaks the URLSession→delegate(self)→closures→driver retain chain
    }

    private func configureSession() {
        send(json: RealtimeSession.sessionUpdate(model: model, silenceDurationMs: silenceDurationMs))
    }

    func sendAudio(_ pcm: Data) {
        // Audio streams continuously from the mic tap. When the socket has dropped (and until the
        // reconnect's session is ready) there is nowhere to send it — drop it SILENTLY rather than
        // firing a failed send per chunk, which previously flooded the log with hundreds of
        // "send error: Operation canceled" lines on a single disconnect.
        lock.lock(); let canSend = connected && !stopped; lock.unlock()
        guard canSend else { return }
        send(json: RealtimeSession.appendAudio(base64PCM: pcm.base64EncodedString()))
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
                self.lock.lock(); let isStopped = self.stopped; self.connected = false; self.lock.unlock()
                if isStopped { return }
                jlog("Jarvis realtime receive failed: \(err)")
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
        case "conversation.item.input_audio_transcription.completed":
            // A completed utterance fragment: record it immediately (so the model's context is
            // whole), but DON'T fire the coach yet — debounce so rapid fragments of one spoken
            // sentence coalesce into a single trigger.
            if let transcriptText = obj["transcript"] as? String, !transcriptText.isEmpty {
                let at = clock.now() - sessionStart
                transcript.append(.init(speaker: .me, text: transcriptText, at: at))
                jlog("🗣 heard: \"\(transcriptText)\"")   // show what was actually said in the viewer
                pending.append(transcriptText)
                resetSilenceTimer()
                scheduleTurnDebounce()
            }
        case "input_audio_buffer.speech_stopped":
            // Server VAD detected end of speech; the actionable turn-end (with transcript) is
            // handled on the completed event above. Just refresh the silence timer here.
            resetSilenceTimer()
        case "session.created", "transcription_session.created":
            lock.lock(); connected = true; lock.unlock()
            jlog("Jarvis realtime: transcription session ready")
        case "error":
            jlog("Jarvis realtime error event: \(text)")
        default:
            break
        }
    }

    /// Coalesce rapid completed-fragments: (re)start a short timer on each fragment; when it settles
    /// we fire ONE trigger for the whole utterance — a direct address if the user named Jarvis,
    /// otherwise an ordinary turn-end. This both fixes residual VAD fragmentation and lets the
    /// wake-word check see the full sentence ("hey jarvis, what's …") rather than a first fragment.
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
        let (utterance, fragments) = pending.flush()

        if fragments > 1 {
            // VAD diagnostic: if this is frequently > 1, the silence window is still too short.
            jlog("🧩 coalesced \(fragments) fragments into one turn")
        }

        if DirectAddress.isAddressed(utterance) {
            jlog("📣 direct address detected")
            onDirectAddress?()
        } else {
            onTurnEnd?()
        }
    }

    // MARK: - Reconnect / keepalive

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        // An intentional Stop closes the socket on purpose; don't alarm the user with it.
        lock.lock(); let isStopped = stopped; connected = false; lock.unlock()
        if isStopped { return }
        jlog("Jarvis realtime socket closed: code \(closeCode.rawValue)")
        scheduleReconnect()
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

    /// Fires the "maybe stuck" silence trigger after `silenceTimeout` of no new transcription.
    private func resetSilenceTimer() {
        let timeout = silenceTimeout
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.silenceTimer?.invalidate()
            self.silenceTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); let isStopped = self.stopped; self.lock.unlock()
                guard !isStopped else { return }   // don't drive a coaching turn on a torn-down pipeline
                let quiet = self.transcript.silenceDuration(now: self.clock.now() - self.sessionStart)
                self.onSilence?(max(timeout, quiet))
            }
            self.lock.unlock()
        }
    }
}
