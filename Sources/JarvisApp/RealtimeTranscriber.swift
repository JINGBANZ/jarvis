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

    private let apiKey: String
    private let model: String
    private let transcript: RollingTranscript
    private let clock: Clock
    private let sessionStart: TimeInterval
    private let silenceTimeout: TimeInterval

    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var silenceTimer: Timer?
    private var pingTimer: Timer?
    private var reconnectAttempt = 0
    private var isReconnecting = false
    private var stopped = false

    init(apiKey: String, model: String, transcript: RollingTranscript, clock: Clock,
         silenceTimeout: TimeInterval = 8) {
        self.apiKey = apiKey
        self.model = model
        self.transcript = transcript
        self.clock = clock
        self.sessionStart = clock.now()
        self.silenceTimeout = silenceTimeout
        super.init()
    }

    func connect() {
        lock.lock(); stopped = false; lock.unlock()
        openSocket()
    }

    private func openSocket() {
        var req = URLRequest(url: RealtimeSession.connectURL())
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: req)
        lock.lock(); self.task = task; isReconnecting = false; lock.unlock()
        task.resume()
        configureSession()
        receiveLoop()
        resetSilenceTimer()
        startPing()
    }

    func stop() {
        lock.lock()
        stopped = true
        silenceTimer?.invalidate(); silenceTimer = nil
        pingTimer?.invalidate(); pingTimer = nil
        let t = task; task = nil
        lock.unlock()
        t?.cancel(with: .goingAway, reason: nil)
    }

    private func configureSession() {
        send(json: RealtimeSession.sessionUpdate(model: model))
    }

    func sendAudio(_ pcm: Data) {
        send(json: RealtimeSession.appendAudio(base64PCM: pcm.base64EncodedString()))
    }

    private func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let str = String(data: data, encoding: .utf8) else { return }
        lock.lock(); let t = task; lock.unlock()
        t?.send(.string(str)) { err in if let err { NSLog("Jarvis realtime send error: \(err)") } }
    }

    private func receiveLoop() {
        lock.lock(); let t = task; lock.unlock()
        t?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                NSLog("Jarvis realtime receive failed: \(err)")
                self.scheduleReconnect()
            case .success(let message):
                self.lock.lock(); self.reconnectAttempt = 0; self.lock.unlock() // healthy
                if case .string(let text) = message { self.handle(text) }
                self.receiveLoop()
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "conversation.item.input_audio_transcription.completed":
            // A completed utterance: record it AND treat it as turn-end. The model now has words.
            if let transcriptText = obj["transcript"] as? String, !transcriptText.isEmpty {
                let at = clock.now() - sessionStart
                transcript.append(.init(speaker: .me, text: transcriptText, at: at))
                resetSilenceTimer()
                onTurnEnd?()
            }
        case "input_audio_buffer.speech_stopped":
            // Server VAD detected end of speech; the actionable turn-end (with transcript) is
            // handled on the completed event above. Just refresh the silence timer here.
            resetSilenceTimer()
        case "session.created", "transcription_session.created":
            NSLog("Jarvis realtime: transcription session ready")
        case "error":
            NSLog("Jarvis realtime error event: \(text)")
        default:
            break
        }
    }

    // MARK: - Reconnect / keepalive

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        NSLog("Jarvis realtime socket closed: code \(closeCode.rawValue)")
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        lock.lock()
        if stopped || isReconnecting { lock.unlock(); return }
        isReconnecting = true
        let attempt = reconnectAttempt
        reconnectAttempt = min(attempt + 1, 6)
        lock.unlock()

        let delay = min(30.0, pow(2.0, Double(attempt)))   // 1, 2, 4, 8, 16, 30…
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let stop = self.stopped; self.lock.unlock()
            guard !stop else { return }
            NSLog("Jarvis realtime: reconnecting (attempt \(attempt + 1))")
            self.openSocket()
        }
    }

    private func startPing() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.pingTimer?.invalidate()
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); let t = self.task; self.lock.unlock()
                t?.sendPing { err in if let err { NSLog("Jarvis realtime ping error: \(err)") } }
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
                let quiet = self.transcript.silenceDuration(now: self.clock.now() - self.sessionStart)
                self.onSilence?(max(timeout, quiet))
            }
            self.lock.unlock()
        }
    }
}
