import Foundation

public enum RealtimeSession {
    /// `?intent=transcription` selects a transcription-only session (`?model=` is
    /// speech-to-speech). GA needs no `OpenAI-Beta` header.
    public static func connectURL() -> URL {
        URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
    }

    /// `noiseReduction` is "near_field", "far_field", or nil to disable. The server rejects it as a
    /// bare string, so it is sent as `{"type": …}`. `keywords` are dropped for GPT-4o Transcribe.
    public static func sessionUpdate(
        model: OpenAITranscriptionModel,
        speaker: Speaker = .me,
        expectedLanguages: [TranscriptionLanguage] = [],
        keywords: [String] = [],
        silenceDurationMs: Int = 1000,
        noiseReduction: String? = "near_field"
    ) -> [String: Any] {
        let expectedLanguages = TranscriptionLanguage.canonicalizing(expectedLanguages)
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
                // OpenAI's Realtime PCM rate is fixed, so this is not a parameter.
                "rate": TranscriptionAudioFormat.pcm16Mono24k.sampleRate,
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

    public static func appendAudio(base64PCM: String) -> [String: Any] {
        ["type": "input_audio_buffer.append", "audio": base64PCM]
    }

    public static func commitAudio(eventID: String) -> [String: Any] {
        ["type": "input_audio_buffer.commit", "event_id": eventID]
    }

    /// Only the `session.update` acknowledgement proves the requested config was accepted;
    /// `session.created` only proves the handshake opened.
    public static func isConfiguredSessionEventType(_ type: String) -> Bool {
        type == "session.updated" || type == "transcription_session.updated"
    }

    /// Sent at the ~60 min session lifetime. An expected rotation, not a fault.
    public static func isSessionExpired(_ event: [String: Any]) -> Bool {
        guard event["type"] as? String == "error",
              let error = event["error"] as? [String: Any] else { return false }
        return error["code"] as? String == "session_expired"
    }

    public static let speechStartedType = "input_audio_buffer.speech_started"
    public static let speechStoppedType = "input_audio_buffer.speech_stopped"
    public static let audioBufferCommittedType = "input_audio_buffer.committed"
    public static let deltaTranscriptionType = "conversation.item.input_audio_transcription.delta"

    /// Server-VAD sessions also emit `input_audio_buffer.committed`, so only client-commit models
    /// bind it to a local boundary.
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

    public static let completedTranscriptionType = "conversation.item.input_audio_transcription.completed"
    public static let failedTranscriptionType = "conversation.item.input_audio_transcription.failed"

    /// Nil means the event has no detected-language field; empty means no reliable prediction.
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

    public static func completedTranscript(from event: [String: Any], speaker: Speaker) -> String? {
        guard event["type"] as? String == completedTranscriptionType,
              let text = event["transcript"] as? String else { return nil }
        return TranscriptFiltering.meaningfulTranscript(text, speaker: speaker)
    }
}
