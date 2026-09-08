import Foundation

/// Pure builders and parsers for the Gemini Live transcription socket — extracted from the WebSocket
/// client so the wire contract is unit-testable (the live socket is not). Verified against Google's
/// Live API transcription guide (2026-09).
public enum GeminiLiveSession {
    private static let endpoint =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    /// Google's documented maximum for `customVocabulary` on the Live API — sending more can get the
    /// whole `setup` request rejected. `TranscriptionPreferences.geminiVocabularyKeywords` enforces
    /// this at write time so a Start can never assemble a setup message that exceeds it.
    public static let maxVocabularyTerms = 1_000

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

    /// Decodes one received frame's UTF-8 JSON bytes into the object the other parsers above expect.
    /// `BidiGenerateContent` sends every server message — including `setupComplete` — as a BINARY
    /// WebSocket frame carrying the same UTF-8 JSON text a TEXT frame would carry, so the transport
    /// layer normalizes both frame kinds to `Data` and shares this one decoder. Returns `nil` for bytes
    /// that are not valid UTF-8 or do not parse as a JSON object; the caller logs and drops the frame
    /// rather than treating it as a transport failure.
    public static func parseFrame(_ bytes: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
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

    /// Whether this event carries a finalized `inputTranscription`, independent of whether its text
    /// survives `TranscriptFiltering` — a pure presence check, symmetric with `hasInterimTranscription`
    /// below. `finalTranscript(from:speaker:)` returns `nil` for two different reasons a caller cannot
    /// tell apart: this frame is not a finalized frame at all, OR it is one whose text the shared
    /// hallucination filter rejected (e.g. a "Thank you." on silence — precisely the artifact
    /// `TranscriptFiltering.hallucinationDenylist` exists to catch). A caller that needs to know
    /// "did Gemini finish recognizing this utterance" — regardless of whether the result turned out to
    /// be speech worth keeping — must use this predicate instead of testing `finalTranscript` for
    /// non-nil.
    public static func hasFinalizedTranscription(_ event: [String: Any]) -> Bool {
        guard let content = event["serverContent"] as? [String: Any],
              let transcription = content["inputTranscription"] as? [String: Any] else { return false }
        return transcription["text"] is String
    }

    /// Whether this event carries a speculative, still-revising interim hypothesis. This is a pure
    /// presence check — it never surfaces the interim text itself, only whether some is there. Callers
    /// use this solely as a "Gemini is actively recognizing speech right now" signal (e.g. to keep a
    /// coaching turn open until the matching final arrives); the text must never reach Activity or the
    /// transcript, so nothing here returns it.
    public static func hasInterimTranscription(_ event: [String: Any]) -> Bool {
        guard let content = event["serverContent"] as? [String: Any],
              let interim = content["interimInputTranscription"] as? [String: Any] else { return false }
        return interim["text"] is String
    }

    /// Whether this event marks Gemini's voice-activity detector starting to hear speech. `voiceActivity`
    /// is a TOP-LEVEL key — a sibling of `serverContent`, not nested inside it — whose value carries a
    /// `"type"` of `"ACTIVITY_START"` or `"ACTIVITY_END"`. Only an exact `"ACTIVITY_START"` match counts;
    /// `ACTIVITY_END`, a missing `voiceActivity`, and any malformed/unexpected `type` all return false.
    ///
    /// Deliberately one-directional: there is no matching `isVoiceActivityEnd` here. Measured against
    /// the live endpoint, `voiceActivity` arrives ~500ms BEFORE the first interim transcription frame
    /// for the same utterance, making it the earliest available "Gemini is recognizing speech" signal —
    /// see the caller's use of it alongside `hasInterimTranscription`. `ACTIVITY_END` is not a substitute
    /// finalization signal: only the finalized transcript may end a turn (see the caller's doc comment).
    public static func isVoiceActivityStart(_ event: [String: Any]) -> Bool {
        guard let activity = event["voiceActivity"] as? [String: Any],
              let type = activity["type"] as? String else { return false }
        return type == "ACTIVITY_START"
    }

    /// Whether this event is Google's `goAway` warning that the current Live API connection is about
    /// to be closed — advance notice of the fixed ~10-minute session cap, not a failure. `goAway` is a
    /// TOP-LEVEL key in `BidiGenerateContentServerMessage`, a sibling of `serverContent` (verified
    /// against https://ai.google.dev/api/live), not nested inside it.
    ///
    /// See https://ai.google.dev/gemini-api/docs/live-api/session-management: the server sends this
    /// message "before the connection will be terminated as ABORTED," which is what lets the caller
    /// drain the socket instead of losing whatever utterance is mid-recognition when it closes.
    public static func isGoAway(_ event: [String: Any]) -> Bool {
        event["goAway"] is [String: Any]
    }

    /// The server's advance warning of how long this socket has left, if present and parseable.
    /// Google encodes `goAway.timeLeft` as a protobuf `Duration` JSON string (e.g. `"9.5s"`, always
    /// suffixed `s`) — see https://protobuf.dev/reference/protobuf/google.protobuf/#duration. Returns
    /// `nil` for a missing, non-string, or non-numeric value so a caller falls back to its own fixed
    /// bound rather than trusting an unparseable server value.
    public static func goAwayTimeLeft(_ event: [String: Any]) -> TimeInterval? {
        guard let goAway = event["goAway"] as? [String: Any],
              let raw = goAway["timeLeft"] as? String, raw.hasSuffix("s") else { return nil }
        return TimeInterval(raw.dropLast())
    }

    /// Maps a WebSocket close code (and, for the one code that needs it, the close reason text) to a
    /// terminal failure. `nil` for every other code, so the caller's normal reconnect-with-backoff
    /// behavior is unaffected.
    ///
    /// Takes the raw close code as an `Int` rather than `URLSessionWebSocketTask.CloseCode`, and the
    /// reason as a plain `String` rather than the `Data` the delegate callback actually receives —
    /// both are Foundation networking types, and this file lives in the coaching kernel, which may
    /// depend only on deterministic in-memory policy, never an OS/transport type (`scripts/check-
    /// coaching-kernel.sh`). `URLSessionWebSocketTask.CloseCode` is `RawRepresentable` with `Int` raw
    /// values, so the call site passes `closeCode.rawValue`; it also UTF-8-decodes the `Data` reason
    /// before passing it here.
    ///
    /// EMPIRICAL FACT, established against the live endpoint with a deliberately invalid API key —
    /// do not "simplify" this away without re-verifying against the real server: Gemini does NOT
    /// reject a bad key with an HTTP 401 at the WebSocket handshake, and does NOT send an `{"error":
    /// ...}` frame either (the Live API has no `error` server-message frame at all — see
    /// https://ai.google.dev/api/live for the exhaustive `BidiGenerateContentServerMessage` list).
    /// The handshake succeeds, and the server then closes the socket with code 1008 (policy
    /// violation). That makes close code 1008 the only signal available for a rejected key, and it is
    /// exactly the "proven permanent provider-boundary failure" AGENTS.md allows to exhaust a target
    /// immediately, skipping the usual reconnect backoff.
    ///
    /// 1008 is not exclusively a rejected key, though — Google reuses it as a GENERIC rejection code
    /// that also covers a retired/unrecognized model id and an unsupported request shape. All three
    /// are still permanent provider-boundary failures a retry cannot fix, so 1008 stays terminal
    /// either way; only the classification differs. The close `reason` text is the one available
    /// signal for telling them apart, but Google does not document its wording as a stable contract,
    /// so this matches a couple of narrow, stable substrings rather than parsing sentence structure.
    /// The captured wording for a rejected key was: "Request had invalid authentication credentials.
    /// Expected OAuth 2 access token, login cookie or other valid authentication credential...".
    /// DEFAULT MUST STAY `.configurationRejected`: an unrecognized 1008 reason must never claim the
    /// key itself was rejected — that would send a user to rotate a perfectly good key.
    public static func terminalFailure(forCloseCode closeCode: Int, reason: String?) -> TranscriptionFailureReason? {
        guard closeCode == 1008 else { return nil }
        let normalized = (reason ?? "").lowercased()
        let authenticationMarkers = ["authentication", "credential"]
        if authenticationMarkers.contains(where: normalized.contains) {
            return .authenticationFailed
        }
        return .configurationRejected
    }
}
