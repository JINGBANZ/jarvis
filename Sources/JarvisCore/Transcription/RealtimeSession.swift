import Foundation

/// Pure builders for the OpenAI GA Realtime **transcription** session — extracted from the
/// WebSocket client so the wire contract is unit-testable (the live socket is not). Verified
/// against the realtime-transcription guide (2026-06).
public enum RealtimeSession {
    public static let sampleRate = 24_000

    /// A transcription-only session is selected at connect time via `?intent=transcription`
    /// (`?model=` is the speech-to-speech form). No `OpenAI-Beta` header in GA.
    public static func connectURL() -> URL {
        URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
    }

    /// The `session.update` payload: `session.type:"transcription"` with config nested under
    /// `session.audio.input` (format / transcription model / server-VAD turn detection).
    /// `server_vad` requires a VAD-capable model such as `gpt-4o-transcribe`.
    ///
    /// `silenceDurationMs` tunes how long a pause must last before the server ends the turn. The
    /// server default (~500 ms) ends a turn on a brief mid-thought pause and chops one spoken
    /// sentence into several utterances; ~1000 ms lets a "thinking aloud" coder finish. We keep
    /// `server_vad` rather than `semantic_vad`, which is reported flaky in transcription-only mode
    /// (it can stop emitting completed events entirely). See wiki/architecture.md (Models and APIs).
    public static func sessionUpdate(model: String, language: String = "en",
                                     silenceDurationMs: Int = 1000) -> [String: Any] {
        [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": sampleRate],
                        "transcription": ["model": model, "language": language],
                        "turn_detection": [
                            "type": "server_vad",
                            "silence_duration_ms": silenceDurationMs,
                        ],
                    ],
                ],
            ],
        ]
    }

    /// Append-audio event (base64 PCM16).
    public static func appendAudio(base64PCM: String) -> [String: Any] {
        ["type": "input_audio_buffer.append", "audio": base64PCM]
    }
}
