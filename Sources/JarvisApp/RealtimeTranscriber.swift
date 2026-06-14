import Foundation
import JarvisCore

/// Client for the OpenAI Realtime API (GA) used as a **transcription session**. Streams PCM16
/// audio, configures server-VAD turn detection, and parses transcription + speech events — adding
/// lines to the RollingTranscript and firing turn/silence events.
///
/// Verified against OpenAI docs (2026-06): GA drops the `OpenAI-Beta` header; the transcription
/// session is configured via `session.update` with `session.type = "transcription"` and config
/// nested under `session.audio.input`; transcription model `gpt-4o-transcribe` supports server-VAD
/// turn detection. Audio is 24 kHz mono PCM16.
///
/// RESIDUAL UNCERTAINTY (confirm on the live smoke run): the bare WebSocket connect for a
/// transcription-only session — if the server requires a model query param, append
/// `?model=gpt-realtime`. Event names below (`input_audio_buffer.speech_stopped`,
/// `conversation.item.input_audio_transcription.completed`) are the documented GA names.
final class RealtimeTranscriber: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var onTurnEnd: (@Sendable () -> Void)?
    var onSilence: (@Sendable (TimeInterval) -> Void)?

    private let apiKey: String
    private let model: String
    private let transcript: RollingTranscript
    private let clock: Clock
    private let sessionStart: TimeInterval
    private let silenceTimeout: TimeInterval

    private var task: URLSessionWebSocketTask?
    private var silenceTimer: Timer?

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
        // GA: no OpenAI-Beta header. Transcription session is selected via session.update below.
        var req = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime")!)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: req)
        self.task = task
        task.resume()
        configureSession()
        receiveLoop()
        resetSilenceTimer()
    }

    func stop() {
        silenceTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    /// GA transcription session config: type + nested audio.input (format / transcription / VAD).
    private func configureSession() {
        send(json: [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "transcription": ["model": model, "language": "en"],
                        "turn_detection": ["type": "server_vad"],
                    ],
                ],
            ],
        ])
    }

    func sendAudio(_ pcm: Data) {
        send(json: ["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
    }

    private func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let str = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(str)) { err in if let err { NSLog("Jarvis realtime send error: \(err)") } }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                NSLog("Jarvis realtime closed: \(err)")
            case .success(let message):
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
            if let transcriptText = obj["transcript"] as? String, !transcriptText.isEmpty {
                let at = clock.now() - sessionStart
                transcript.append(.init(speaker: .me, text: transcriptText, at: at))
                resetSilenceTimer()
            }
        case "input_audio_buffer.speech_stopped":
            // Server VAD detected end of a spoken turn.
            onTurnEnd?()
            resetSilenceTimer()
        case "error":
            NSLog("Jarvis realtime error event: \(text)")
        default:
            break
        }
    }

    /// Fires the "maybe stuck" silence trigger after `silenceTimeout` of no new transcription.
    private func resetSilenceTimer() {
        let timeout = silenceTimeout
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.silenceTimer?.invalidate()
            self.silenceTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                guard let self else { return }
                let quiet = self.transcript.silenceDuration(now: self.clock.now() - self.sessionStart)
                self.onSilence?(max(timeout, quiet))
            }
        }
    }
}
