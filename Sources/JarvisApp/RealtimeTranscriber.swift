import Foundation
import JarvisCore

/// Minimal client for the OpenAI Realtime API (GA). Sends PCM16 audio and parses transcription +
/// turn-detection events, appending lines to the RollingTranscript and firing turn/silence events.
///
/// HONEST LIMITATION: the exact Realtime event names, the auth/beta header, and the model id
/// (`gpt-realtime-2`) follow the documented GA shapes but were last confirmed pre-cutoff. They are
/// isolated to this one file and must be checked against live OpenAI docs during the smoke run.
/// If `gpt-realtime-2` accepts image input, a future simplification merges the brain + transcriber
/// (spec §5 note) — out of scope here.
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
        var req = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=\(model)")!)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // Header name per Realtime docs; confirm against live docs at run time.
        req.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: req)
        self.task = task
        task.resume()
        configureSession()
        receiveLoop()
        resetSilenceTimer()
    }

    /// Enable input-audio transcription + server turn detection.
    private func configureSession() {
        send(json: [
            "type": "session.update",
            "session": [
                "input_audio_format": "pcm16",
                "input_audio_transcription": ["model": model],
                "turn_detection": ["type": "server_vad"],
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
        case "input_audio_buffer.speech_stopped", "response.done":
            onTurnEnd?()
            resetSilenceTimer()
        default:
            break
        }
    }

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
