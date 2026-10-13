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
        let expectation = TranscriptionLanguageExpectation(languages: expectedLanguages)
        let expectedLanguages = expectation.languages
        var transcription: [String: Any] = ["model": model.rawValue]
        if let context = TranscriptionTarget.openAI(model).context(for: speaker, expectation: expectation) {
            transcription["prompt"] = context
        }
        switch model {
        case .gpt4oTranscribe:
            if expectedLanguages.count == 1, let language = expectedLanguages.first {
                transcription["language"] = language.singularHint
            }
        case .gptTranscribe, .gptLiveTranscribe:
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

    public static func acceptsConfiguration(
        event: [String: Any],
        model: OpenAITranscriptionModel,
        speaker: Speaker,
        expectedLanguages: [TranscriptionLanguage]
    ) -> Bool {
        guard let type = event["type"] as? String, isConfiguredSessionEventType(type),
              let session = event["session"] as? [String: Any],
              session["type"] as? String == "transcription",
              let audio = session["audio"] as? [String: Any],
              let input = audio["input"] as? [String: Any],
              let transcription = input["transcription"] as? [String: Any],
              transcription["model"] as? String == model.rawValue else { return false }
        let expectation = TranscriptionLanguageExpectation(languages: expectedLanguages)
        let prompt = TranscriptionTarget.openAI(model).context(for: speaker, expectation: expectation)
        guard optionalString(transcription["prompt"], matches: prompt) else { return false }
        switch model {
        case .gpt4oTranscribe:
            let language = expectation.languages.count == 1 ? expectation.languages.first?.singularHint : nil
            return optionalString(transcription["language"], matches: language)
                && optionalLanguages(transcription["languages"], match: [])
        case .gptTranscribe, .gptLiveTranscribe:
            let expected = expectation.languages.map(\.multipleHint)
            return optionalLanguages(transcription["languages"], match: expected)
                && optionalString(transcription["language"], matches: nil)
        }
    }

    private static func optionalString(_ value: Any?, matches expected: String?) -> Bool {
        if value == nil || value is NSNull { return expected == nil }
        guard let actual = value as? String else { return false }
        return actual == (expected ?? "")
    }

    private static func optionalLanguages(_ value: Any?, match expected: [String]) -> Bool {
        if value == nil || value is NSNull { return expected.isEmpty }
        guard let actual = value as? [String] else { return false }
        return actual.sorted() == expected.sorted()
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
