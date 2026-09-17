import Foundation

public enum GeminiLiveSession {
    private static let endpoint =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    /// Google's documented `customVocabulary` limit. More can get the whole `setup` rejected.
    public static let maxVocabularyTerms = 1_000

    /// Gemini takes the key as a query parameter, so never log this URL; log `redactedEndpoint`.
    /// The force-unwraps only fail on a malformed `endpoint` constant.
    public static func connectURL(apiKey: String) -> URL {
        var components = URLComponents(string: endpoint)!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        return components.url!
    }

    public static let redactedEndpoint = endpoint

    /// `languageCodes` is sent even when empty, because `[]` is what selects automatic detection.
    public static func setupMessage(
        model: GeminiTranscriptionModel,
        languages: [TranscriptionLanguage] = [],
        vocabulary: [String] = [],
        mode: GeminiTranscriptionMode = .verbatim
    ) -> [String: Any] {
        var transcription: [String: Any] = [
            "languageCodes": TranscriptionLanguage.canonicalizing(languages).map(\.geminiHint),
            "mode": mode.wireValue,
        ]
        if !vocabulary.isEmpty {
            transcription["customVocabulary"] = vocabulary
        }
        return [
            "setup": [
                "model": model.wireModelName,
                "generationConfig": ["responseModalities": ["TEXT"]],
                "inputAudioTranscription": transcription,
            ],
        ]
    }

    /// `sampleRate` must match the PCM actually sent.
    public static func audioFrame(base64PCM: String, sampleRate: Int) -> [String: Any] {
        ["realtimeInput": ["audio": [
            "data": base64PCM,
            "mimeType": "audio/pcm;rate=\(sampleRate)",
        ]]]
    }

    public static func audioStreamEnd() -> [String: Any] {
        ["realtimeInput": ["audioStreamEnd": true]]
    }

    /// Gemini sends every server message, `setupComplete` included, as a binary frame of UTF-8
    /// JSON, so both frame kinds decode here. Nil means drop the frame, not a transport failure.
    public static func parseFrame(_ bytes: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
    }

    public static func isSetupComplete(_ event: [String: Any]) -> Bool {
        event["setupComplete"] != nil
    }

    /// Only `inputTranscription` counts. `interimInputTranscription` is still being revised, and
    /// appending it would log phantom turns.
    public static func finalTranscript(from event: [String: Any], speaker: Speaker) -> String? {
        guard let content = event["serverContent"] as? [String: Any],
              let transcription = content["inputTranscription"] as? [String: Any],
              let text = transcription["text"] as? String else { return nil }
        return TranscriptFiltering.meaningfulTranscript(text, speaker: speaker)
    }

    /// Use this, not a non-nil `finalTranscript`, to learn that Gemini finished an utterance:
    /// `finalTranscript` is also nil when the hallucination filter rejects the text.
    public static func hasFinalizedTranscription(_ event: [String: Any]) -> Bool {
        guard let content = event["serverContent"] as? [String: Any],
              let transcription = content["inputTranscription"] as? [String: Any] else { return false }
        return transcription["text"] is String
    }

    /// Presence only. Interim text must never reach Activity or the transcript.
    public static func hasInterimTranscription(_ event: [String: Any]) -> Bool {
        guard let content = event["serverContent"] as? [String: Any],
              let interim = content["interimInputTranscription"] as? [String: Any] else { return false }
        return interim["text"] is String
    }

    /// `voiceActivity` is top-level, not inside `serverContent`, and arrives ~500 ms before the
    /// first interim frame. There is deliberately no end check: only a finalized transcript may end
    /// a turn.
    public static func isVoiceActivityStart(_ event: [String: Any]) -> Bool {
        guard let activity = event["voiceActivity"] as? [String: Any],
              let type = activity["type"] as? String else { return false }
        return type == "ACTIVITY_START"
    }

    /// `goAway` is top-level, not inside `serverContent`. It warns of the ~10-minute session cap
    /// and is not a failure.
    public static func isGoAway(_ event: [String: Any]) -> Bool {
        event["goAway"] is [String: Any]
    }

    /// `timeLeft` is a protobuf `Duration` JSON string such as `"9.5s"`. Nil when missing or
    /// unparseable, so the caller uses its own bound.
    public static func goAwayTimeLeft(_ event: [String: Any]) -> TimeInterval? {
        guard let goAway = event["goAway"] as? [String: Any],
              let raw = goAway["timeLeft"] as? String, raw.hasSuffix("s") else { return nil }
        return TimeInterval(raw.dropLast())
    }
}
