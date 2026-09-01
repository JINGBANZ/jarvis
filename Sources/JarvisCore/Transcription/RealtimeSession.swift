import Foundation

/// Pure builders for the OpenAI GA Realtime **transcription** session — extracted from the
/// WebSocket client so the wire contract is unit-testable (the live socket is not). Verified
/// against the realtime-transcription guide (2026-08).
public enum RealtimeSession {
    /// A transcription-only session is selected at connect time via `?intent=transcription`
    /// (`?model=` is the speech-to-speech form). No `OpenAI-Beta` header in GA.
    public static func connectURL() -> URL {
        URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
    }

    /// The `session.update` payload: `session.type:"transcription"` with config nested under
    /// `session.audio.input` (format / transcription model / model-compatible turn detection).
    ///
    /// GPT-4o accepts the legacy singular `language` hint. GPT Transcribe and GPT Live accept the
    /// plural `languages` list and a free-form recording context; GPT Live also receives the low
    /// streaming-delay setting. GPT-4o sessions with zero or multiple expected languages omit
    /// `language` and use automatic recognition.
    ///
    /// GPT-4o uses `server_vad`; `silenceDurationMs` tunes how long a pause must last before the
    /// server ends the turn. GPT Transcribe and GPT Live require committed-turn transcription, so
    /// their payloads clear `turn_detection` and the client commits boundaries found by local
    /// WebRTC VAD. See wiki/architecture.md (Models and APIs).
    ///
    /// `noiseReduction` ("near_field" for a headset/close mic, "far_field" for a laptop/room mic, or
    /// nil to disable) filters the input buffer *before* it reaches VAD and the model — OpenAI's
    /// first-line defense against non-speech blips firing the VAD and producing phantom transcripts.
    /// Sent as an object `{"type": …}`; a bare string is rejected by the server.
    ///
    /// `keywords` are literal vocabulary terms (jargon, names) that bias recognition. Only GPT
    /// Transcribe and GPT Live accept them, matching their `prompt` support; GPT-4o Transcribe has
    /// neither, so keywords are silently inert there rather than rejected by the server.
    public static func sessionUpdate(
        model: OpenAITranscriptionModel,
        speaker: Speaker = .me,
        expectedLanguages: [OpenAITranscriptionLanguage] = [],
        keywords: [String] = [],
        silenceDurationMs: Int = 1000,
        noiseReduction: String? = "near_field"
    ) -> [String: Any] {
        let expectedLanguages = OpenAITranscriptionLanguage.canonicalizing(expectedLanguages)
        var transcription: [String: Any] = ["model": model.rawValue]
        switch model {
        case .gpt4oTranscribe:
            if expectedLanguages.count == 1, let language = expectedLanguages.first {
                transcription["language"] = language.singularHint
            }
        case .gptTranscribe, .gptLiveTranscribe:
            transcription["prompt"] = JarvisPrompts.Transcription.context(for: speaker)
            if !expectedLanguages.isEmpty {
                transcription["languages"] = expectedLanguages.map(\.multipleHint)
            }
            if !keywords.isEmpty {
                transcription["keywords"] = keywords
            }
            if model == .gptLiveTranscribe {
                transcription["delay"] = "low"
            }
        }

        let turnDetection: Any
        switch model.turnDetectionStrategy {
        case .serverVAD:
            turnDetection = [
                "type": "server_vad",
                "silence_duration_ms": silenceDurationMs,
            ]
        case .clientCommit:
            turnDetection = NSNull()
        }

        var input: [String: Any] = [
            "format": [
                "type": "audio/pcm",
                "rate": TranscriptionAudioFormat.pcm16Mono.sampleRate,
            ],
            "transcription": transcription,
            "turn_detection": turnDetection,
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

    /// Explicitly finalize the current input buffer for a client-commit model.
    public static func commitAudio(eventID: String) -> [String: Any] {
        ["type": "input_audio_buffer.commit", "event_id": eventID]
    }

    /// A socket is usable only after the server acknowledges `session.update`. The earlier created
    /// event proves the handshake opened, but not that the requested transcription model/format/VAD
    /// configuration was accepted.
    public static func isConfiguredSessionEventType(_ type: String) -> Bool {
        type == "session.updated" || type == "transcription_session.updated"
    }

    /// True if a parsed wire event is the server's `session_expired` error — emitted when a transcription
    /// session hits its maximum lifetime (~60 min) and the socket rotates. An EXPECTED rotation, not a
    /// fault (callers log it calmly and quiet the reconnect noise; see `RealtimeTranscriber`).
    public static func isSessionExpired(_ event: [String: Any]) -> Bool {
        guard event["type"] as? String == "error",
              let error = event["error"] as? [String: Any] else { return false }
        return error["code"] as? String == "session_expired"
    }

    public static let speechStartedType = "input_audio_buffer.speech_started"
    public static let speechStoppedType = "input_audio_buffer.speech_stopped"
    public static let audioBufferCommittedType = "input_audio_buffer.committed"
    public static let deltaTranscriptionType = "conversation.item.input_audio_transcription.delta"

    /// Server-VAD sessions may emit `input_audio_buffer.committed` as part of their normal server-owned
    /// turn lifecycle. Only client-commit models bind that event to a Jarvis-managed local boundary.
    public enum AudioBufferCommitEvent: Equatable, Sendable {
        case ignored
        case malformedAcknowledgement
        case acknowledgement(itemID: String)
    }

    public static func audioBufferCommitEvent(
        from event: [String: Any],
        model: OpenAITranscriptionModel
    ) -> AudioBufferCommitEvent {
        guard event["type"] as? String == audioBufferCommittedType,
              model.turnDetectionStrategy == .clientCommit else {
            return .ignored
        }
        guard let itemID = event["item_id"] as? String else {
            return .malformedAcknowledgement
        }
        return .acknowledgement(itemID: itemID)
    }

    /// The event type the server emits when an utterance's transcription is final.
    public static let completedTranscriptionType = "conversation.item.input_audio_transcription.completed"
    public static let failedTranscriptionType = "conversation.item.input_audio_transcription.failed"

    /// GPT Transcribe's detected language codes from a completed event. `nil` means the event carries
    /// no detected-language field; an empty array is meaningful and means no reliable prediction.
    public static func detectedLanguageCodes(from event: [String: Any]) -> [String]? {
        guard event["type"] as? String == completedTranscriptionType,
              let languages = event["languages"] as? [[String: Any]] else {
            return nil
        }
        return languages.compactMap { language in
            guard let code = language["code"] as? String else { return nil }
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// Classify only failures that cannot recover on the next utterance. Realtime also uses the
    /// failed-transcription event for item-local failures such as `audio_unintelligible`, so an
    /// unrecognized code must remain diagnostic rather than tearing down an otherwise usable session.
    public static func terminalTranscriptionFailure(
        from event: [String: Any]
    ) -> TranscriptionFailureReason? {
        guard let eventType = event["type"] as? String,
              eventType == failedTranscriptionType || eventType == "error",
              let error = event["error"] as? [String: Any] else { return nil }
        let code = (error["code"] as? String)?.lowercased()
        let type = (error["type"] as? String)?.lowercased()

        switch code {
        case "insufficient_quota", "billing_hard_limit_reached", "billing_not_active":
            return .quotaExceeded
        case "invalid_api_key":
            return .authenticationFailed
        case "permission_denied", "organization_deactivated", "account_deactivated",
             "unsupported_country_region_territory":
            return .accessDenied
        case "model_not_found":
            return .configurationRejected
        case "invalid_value":
            let parameter = (error["param"] as? String)?.lowercased()
            if eventType == "error", parameter?.hasPrefix("session.") == true {
                return .configurationRejected
            }
        default:
            break
        }

        switch type {
        case "authentication_error": return .authenticationFailed
        case "permission_error": return .accessDenied
        default: return nil
        }
    }

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
