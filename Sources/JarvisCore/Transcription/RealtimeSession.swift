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

    /// True if a parsed wire event is the server's `session_expired` error — emitted when a transcription
    /// session hits its maximum lifetime (~60 min) and the socket rotates. An EXPECTED rotation, not a
    /// fault (callers log it calmly and quiet the reconnect noise; see `RealtimeTranscriber`).
    public static func isSessionExpired(_ event: [String: Any]) -> Bool {
        guard event["type"] as? String == "error",
              let error = event["error"] as? [String: Any] else { return false }
        return error["code"] as? String == "session_expired"
    }

    /// The event type the server emits when an utterance's transcription is final.
    public static let completedTranscriptionType = "conversation.item.input_audio_transcription.completed"

    /// The transcript text from a parsed realtime event, if it is a **completed** input-audio
    /// transcription carrying real speech — otherwise nil. Pure and unit-testable; the live socket
    /// is not, so this is where the wire→text parsing (and hallucination filtering) is verified.
    ///
    /// `speaker` scopes the phrase denylist: a bare "Thank you."/"Thanks" is a silence hallucination on
    /// the *me* (mic) side but a real turn-ending reply on the *them* (system-audio) side, so the
    /// denylist applies to `.me` only. The punctuation/whitespace-only drop applies to both.
    public static func completedTranscript(from event: [String: Any], speaker: Speaker) -> String? {
        guard event["type"] as? String == completedTranscriptionType,
              let text = event["transcript"] as? String else { return nil }
        return meaningfulTranscript(text, speaker: speaker)
    }

    /// Stock non-speech hallucinations gpt-4o-transcribe / Whisper emit when VAD fires on silence —
    /// mostly YouTube-caption artifacts the model absorbed in training. Lower-cased, punctuation
    /// stripped; matched only against a whole utterance (see `meaningfulTranscript`) so a real sentence
    /// containing these words survives. Conservative on purpose — add only well-attested phrases here.
    /// Applied to the `.me` side only (see `completedTranscript`). "bye" is deliberately absent: it is a
    /// well-formed sign-off, and the punctuation filter already catches the lone-"." artifact.
    static let hallucinationDenylist: Set<String> = [
        "you", "thank you", "thank you very much", "thanks", "thanks for watching",
        "thank you for watching", "please subscribe",
    ]

    /// Returns the utterance trimmed if it is real speech, else nil — the Layer-3 text filter for the
    /// `"."`-on-silence problem. Drops two kinds of non-speech the model invents:
    ///   1. punctuation/whitespace-only output (a lone "." has no letter or digit) — both speakers, and
    ///   2. an utterance that, normalized, is exactly a known caption-artifact phrase — `.me` only.
    /// Letting either through logs a phantom `heard` line, resets the silence timer, and fires a turn.
    static func meaningfulTranscript(_ raw: String, speaker: Speaker) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        if speaker == .me {
            // Strip only the trailing punctuation the transcriber actually emits; no apostrophe (it
            // belongs inside contractions, and trimming it could mangle a legitimately-quoted word).
            let normalized = trimmed.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?…\" "))
            guard !hallucinationDenylist.contains(normalized) else { return nil }
        }
        return trimmed
    }
}
