import Foundation

/// Pure builders and parsers for the Gemini Live transcription socket — extracted from the WebSocket
/// client so the wire contract is unit-testable (the live socket is not). Verified against Google's
/// Live API transcription guide (2026-09).
public enum GeminiLiveSession {
    private static let endpoint =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    /// Gemini authenticates with a query parameter rather than a header, so the key is part of the
    /// URL. Never log this value — log `redactedEndpoint` instead. The force-unwraps operate on the
    /// hardcoded `endpoint` constant above, not on `apiKey`, so they cannot fail at runtime.
    public static func connectURL(apiKey: String) -> URL {
        var components = URLComponents(string: endpoint)!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        return components.url!
    }

    /// The endpoint without its credential-bearing query, safe for diagnostics.
    public static let redactedEndpoint = endpoint

    /// The opening `setup` frame. The socket is not usable until the server acknowledges it, which
    /// `isSetupComplete` detects — an open socket alone does not prove the model or the audio format
    /// was accepted.
    ///
    /// `languageCodes` is always sent, including empty: `[]` is what selects automatic detection
    /// across every language Gemini supports, rather than an omission the server would have to guess at.
    public static func setupMessage(
        model: GeminiTranscriptionModel,
        languages: [TranscriptionLanguage] = [],
        vocabulary: [String] = [],
        mode: GeminiTranscriptionMode = .verbatim
    ) -> [String: Any] {
        var transcription: [String: Any] = [
            "languageCodes": TranscriptionLanguage.canonicalizing(languages).map(\.multipleHint),
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

    /// One audio chunk. The rate travels in the mime type and must match the PCM actually sent.
    public static func audioFrame(base64PCM: String, sampleRate: Int) -> [String: Any] {
        ["realtimeInput": ["audio": [
            "data": base64PCM,
            "mimeType": "audio/pcm;rate=\(sampleRate)",
        ]]]
    }

    /// Tells the server no more audio is coming so it can finalize the last utterance.
    public static func audioStreamEnd() -> [String: Any] {
        ["realtimeInput": ["audioStreamEnd": true]]
    }

    /// The server's acknowledgement that the requested model and transcription config were accepted.
    public static func isSetupComplete(_ event: [String: Any]) -> Bool {
        event["setupComplete"] != nil
    }

    /// Finalized transcript text, if this event carries real speech.
    ///
    /// Only `inputTranscription` counts. `interimInputTranscription` is a speculative hypothesis that
    /// is revised while the speaker is still talking; appending it would log phantom turns and reset
    /// the silence timer mid-utterance.
    public static func finalTranscript(from event: [String: Any], speaker: Speaker) -> String? {
        guard let content = event["serverContent"] as? [String: Any],
              let transcription = content["inputTranscription"] as? [String: Any],
              let text = transcription["text"] as? String else { return nil }
        return TranscriptFiltering.meaningfulTranscript(text, speaker: speaker)
    }

    /// Classify only failures that cannot recover on a reconnect. An unrecognized or transient status
    /// stays diagnostic, so one bad frame never tears down an otherwise usable session.
    public static func terminalFailure(from event: [String: Any]) -> TranscriptionFailureReason? {
        guard let error = event["error"] as? [String: Any] else { return nil }
        let status = (error["status"] as? String)?.uppercased()
        switch status {
        case "UNAUTHENTICATED": return .authenticationFailed
        case "RESOURCE_EXHAUSTED": return .quotaExceeded
        case "PERMISSION_DENIED": return .accessDenied
        case "INVALID_ARGUMENT", "NOT_FOUND", "FAILED_PRECONDITION": return .configurationRejected
        default: return nil
        }
    }
}
