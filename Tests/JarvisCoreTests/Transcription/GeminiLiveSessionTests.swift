import Testing
import Foundation
@testable import JarvisCore

@Suite struct GeminiLiveSessionTests {
    private func setup(
        languages: [TranscriptionLanguage] = [],
        vocabulary: [String] = [],
        mode: GeminiTranscriptionMode = .verbatim
    ) -> [String: Any] {
        GeminiLiveSession.setupMessage(
            model: .geminiTranscribeLive, languages: languages, vocabulary: vocabulary, mode: mode)
    }

    private func transcription(_ message: [String: Any]) -> [String: Any] {
        let setup = message["setup"] as? [String: Any]
        return setup?["inputAudioTranscription"] as? [String: Any] ?? [:]
    }

    @Test func connectURLCarriesTheKeyAsAQueryItem() {
        let url = GeminiLiveSession.connectURL(apiKey: "gem-secret")
        #expect(url.scheme == "wss")
        #expect(url.host == "generativelanguage.googleapis.com")
        #expect(url.path == "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(items?.first(where: { $0.name == "key" })?.value == "gem-secret")
    }

    /// The key lives in the URL, so anything logged must be the query-free form.
    @Test func redactedEndpointDropsTheQueryString() {
        #expect(!GeminiLiveSession.redactedEndpoint.contains("key"))
        #expect(GeminiLiveSession.redactedEndpoint.hasPrefix("wss://generativelanguage.googleapis.com/"))
    }

    @Test func setupRequestsTextOnlyResponsesFromTheLiveModel() {
        let message = setup()
        let inner = message["setup"] as? [String: Any]
        #expect(inner?["model"] as? String == "models/gemini-3.5-transcribe-live")
        let generation = inner?["generationConfig"] as? [String: Any]
        #expect(generation?["responseModalities"] as? [String] == ["TEXT"])
    }

    /// An empty list is sent, not omitted: `[]` is what selects automatic detection.
    @Test func noSelectedLanguagesSendsAnEmptyList() {
        #expect(transcription(setup())["languageCodes"] as? [String] == [])
    }

    @Test func selectedLanguagesAreSentAsBCP47Codes() {
        let codes = transcription(setup(languages: [.english, .mandarinChinese]))["languageCodes"]
        #expect(codes as? [String] == ["en", "zh-cn"])
    }

    @Test func vocabularyAndModeAreCarriedOnTheSetup() {
        let inner = transcription(setup(vocabulary: ["gRPC", "Kubernetes"], mode: .smart))
        #expect(inner["customVocabulary"] as? [String] == ["gRPC", "Kubernetes"])
        #expect(inner["mode"] as? String == "SMART")
    }

    @Test func audioFrameIsBase64PCMWithTheMatchingRate() {
        let frame = GeminiLiveSession.audioFrame(base64PCM: "AAECAw==", sampleRate: 16_000)
        let input = frame["realtimeInput"] as? [String: Any]
        let audio = input?["audio"] as? [String: Any]
        #expect(audio?["data"] as? String == "AAECAw==")
        #expect(audio?["mimeType"] as? String == "audio/pcm;rate=16000")
    }

    @Test func streamEndIsSignalledExplicitly() {
        let end = GeminiLiveSession.audioStreamEnd()
        let input = end["realtimeInput"] as? [String: Any]
        #expect(input?["audioStreamEnd"] as? Bool == true)
    }

    /// Gemini's `BidiGenerateContent` endpoint sends its JSON responses as BINARY frames carrying the
    /// same UTF-8 JSON text a TEXT frame would, so the transport layer feeds both frame kinds through
    /// this one decoder.
    @Test func parseFrameDecodesUTF8JSONBytesFromEitherFrameKind() {
        let bytes = Data(#"{"setupComplete": {}}"#.utf8)
        let parsed = GeminiLiveSession.parseFrame(bytes)
        #expect(parsed != nil)
        #expect(GeminiLiveSession.isSetupComplete(parsed ?? [:]))
    }

    /// Bytes that are not valid UTF-8, or that are valid UTF-8 but not a JSON object, must decode to
    /// `nil` so the caller can log and drop the frame instead of tearing down the socket.
    @Test func parseFrameRejectsUndecodableOrUnparsableBytes() {
        #expect(GeminiLiveSession.parseFrame(Data([0xFF, 0xFE, 0xFD])) == nil)
        #expect(GeminiLiveSession.parseFrame(Data("not json".utf8)) == nil)
        #expect(GeminiLiveSession.parseFrame(Data("[1, 2, 3]".utf8)) == nil)
    }

    @Test func setupIsCompleteOnlyOnTheServersAcknowledgement() {
        #expect(GeminiLiveSession.isSetupComplete(["setupComplete": [String: Any]()]))
        #expect(!GeminiLiveSession.isSetupComplete(["serverContent": [String: Any]()]))
    }

    @Test func finalTranscriptIsReadFromTheFinalizedField() {
        let event: [String: Any] = ["serverContent": [
            "inputTranscription": ["text": "let's talk about indexes"],
        ]]
        #expect(GeminiLiveSession.finalTranscript(from: event, speaker: .me)
            == "let's talk about indexes")
    }

    /// Interim hypotheses are speculative and are never appended to the transcript.
    @Test func interimTranscriptNeverYieldsText() {
        let event: [String: Any] = ["serverContent": [
            "interimInputTranscription": ["text": "let's talk about ind"],
        ]]
        #expect(GeminiLiveSession.finalTranscript(from: event, speaker: .me) == nil)
    }

    /// An interim frame is the only thing that should read as "recognition in flight" — the presence
    /// check must not require or leak the text itself.
    @Test func hasInterimTranscriptionIsTrueOnlyForAnInterimFrame() {
        let event: [String: Any] = ["serverContent": [
            "interimInputTranscription": ["text": "let's talk about ind"],
        ]]
        #expect(GeminiLiveSession.hasInterimTranscription(event))
    }

    /// A finalized-only frame must NOT read as interim, or the "recognition in flight" flag would
    /// never clear once the final it was waiting for actually arrives.
    @Test func hasInterimTranscriptionIsFalseForAFinalizedOnlyFrame() {
        let event: [String: Any] = ["serverContent": [
            "inputTranscription": ["text": "let's talk about indexes"],
        ]]
        #expect(!GeminiLiveSession.hasInterimTranscription(event))
    }

    @Test func hasInterimTranscriptionIsFalseForUnrelatedFrames() {
        #expect(!GeminiLiveSession.hasInterimTranscription(["setupComplete": [String: Any]()]))
        #expect(!GeminiLiveSession.hasInterimTranscription([:]))
    }

    @Test func finalTranscriptAppliesTheSharedHallucinationFilter() {
        let event: [String: Any] = ["serverContent": ["inputTranscription": ["text": "Thank you."]]]
        #expect(GeminiLiveSession.finalTranscript(from: event, speaker: .me) == nil)
        #expect(GeminiLiveSession.finalTranscript(from: event, speaker: .them) == "Thank you.")
    }

    @Test func authenticationAndQuotaErrorsAreTerminal() {
        #expect(GeminiLiveSession.terminalFailure(from: ["error": [
            "code": 401, "status": "UNAUTHENTICATED",
        ]]) == .authenticationFailed)
        #expect(GeminiLiveSession.terminalFailure(from: ["error": [
            "code": 429, "status": "RESOURCE_EXHAUSTED",
        ]]) == .quotaExceeded)
        #expect(GeminiLiveSession.terminalFailure(from: ["error": [
            "code": 403, "status": "PERMISSION_DENIED",
        ]]) == .accessDenied)
        #expect(GeminiLiveSession.terminalFailure(from: ["error": [
            "code": 400, "status": "INVALID_ARGUMENT",
        ]]) == .configurationRejected)
        #expect(GeminiLiveSession.terminalFailure(from: ["error": [
            "code": 404, "status": "NOT_FOUND",
        ]]) == .configurationRejected)
    }

    /// An unknown or transient server error must stay diagnostic rather than tearing the session down.
    @Test func unknownErrorsAreNotTerminal() {
        #expect(GeminiLiveSession.terminalFailure(from: ["error": [
            "code": 503, "status": "UNAVAILABLE",
        ]]) == nil)
        #expect(GeminiLiveSession.terminalFailure(from: ["serverContent": [String: Any]()]) == nil)
    }

    /// Gemini rejects a bad API key by closing the socket with 1008, not with an `{"error": ...}`
    /// frame — verified empirically against the live endpoint. This is the only close code that
    /// should skip reconnect backoff and go straight to a terminal failure.
    @Test func policyViolationCloseIsTerminalAuthenticationFailure() {
        #expect(GeminiLiveSession.terminalFailure(forCloseCode: 1008) == .authenticationFailed)
    }

    /// Every other close code — normal closure, going away, abnormal closure, etc. — must stay
    /// non-terminal so the caller's existing reconnect-with-backoff behavior is unaffected.
    @Test func otherCloseCodesAreNotTerminal() {
        #expect(GeminiLiveSession.terminalFailure(forCloseCode: 1000) == nil) // normal closure
        #expect(GeminiLiveSession.terminalFailure(forCloseCode: 1001) == nil) // going away
        #expect(GeminiLiveSession.terminalFailure(forCloseCode: 1006) == nil) // abnormal closure
        #expect(GeminiLiveSession.terminalFailure(forCloseCode: 1011) == nil) // internal server error
    }
}
