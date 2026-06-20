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
    ///
    /// `noiseReduction` ("near_field" for a headset/close mic, "far_field" for a laptop/room mic, or
    /// nil to disable) filters the input buffer *before* it reaches VAD and the model — OpenAI's
    /// first-line defense against non-speech blips firing the VAD and producing phantom transcripts.
    /// Sent as an object `{"type": …}`; a bare string is rejected by the server.
    public static func sessionUpdate(model: String, language: String = "en",
                                     silenceDurationMs: Int = 1000,
                                     noiseReduction: String? = "near_field") -> [String: Any] {
        var input: [String: Any] = [
            "format": ["type": "audio/pcm", "rate": sampleRate],
            "transcription": ["model": model, "language": language],
            "turn_detection": [
                "type": "server_vad",
                "silence_duration_ms": silenceDurationMs,
            ],
        ]
        if let noiseReduction {
            input["noise_reduction"] = ["type": noiseReduction]
        }
        return [
            "type": "session.update",
            "session": ["type": "transcription", "audio": ["input": input]],
        ]
    }

    /// Append-audio event (base64 PCM16).
    public static func appendAudio(base64PCM: String) -> [String: Any] {
        ["type": "input_audio_buffer.append", "audio": base64PCM]
    }

    /// The event type the server emits when an utterance's transcription is final.
    public static let completedTranscriptionType = "conversation.item.input_audio_transcription.completed"

    /// The transcript text from a parsed realtime event, if it is a **completed** input-audio
    /// transcription carrying real speech — otherwise nil. Pure and unit-testable; the live socket
    /// is not, so this is where the wire→text parsing (and hallucination filtering) is verified.
    public static func completedTranscript(from event: [String: Any]) -> String? {
        guard event["type"] as? String == completedTranscriptionType,
              let text = event["transcript"] as? String else { return nil }
        return meaningfulTranscript(text)
    }

    /// Stock non-speech hallucinations gpt-4o-transcribe / Whisper emit when VAD fires on silence —
    /// mostly YouTube-caption artifacts the model absorbed in training. Lower-cased, punctuation
    /// stripped; matched only against a whole utterance (see `meaningfulTranscript`) so a real sentence
    /// containing these words survives. Conservative on purpose — add only well-attested phrases here.
    static let hallucinationDenylist: Set<String> = [
        "you", "thank you", "thank you very much", "thanks", "thanks for watching",
        "thank you for watching", "please subscribe", "bye",
    ]

    /// Returns the utterance trimmed if it is real speech, else nil — the Layer-3 text filter for the
    /// `"."`-on-silence problem. Drops two kinds of non-speech the model invents:
    ///   1. punctuation/whitespace-only output (a lone "." has no letter or digit), and
    ///   2. an utterance that, normalized, is exactly a known caption-artifact phrase.
    /// Letting either through logs a phantom `heard` line, resets the silence timer, and fires a turn.
    static func meaningfulTranscript(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        let normalized = trimmed.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?…\"' "))
        guard !hallucinationDenylist.contains(normalized) else { return nil }
        return trimmed
    }
}
