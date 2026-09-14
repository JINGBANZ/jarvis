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

    /// Gemini's own documented codes (`geminiHint`), not OpenAI's `multipleHint` — see
    /// `TranscriptionLanguage.geminiHint`'s doc comment for why they differ.
    @Test func selectedLanguagesAreSentAsGeminisDocumentedCodes() {
        let codes = transcription(setup(languages: [.english, .mandarinChinese]))["languageCodes"]
        #expect(codes as? [String] == ["en-US", "cmn-Hans-CN"])
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

    @Test func hasFinalizedTranscriptionIsTrueForOrdinaryFinalizedText() {
        let event: [String: Any] = ["serverContent": [
            "inputTranscription": ["text": "let's talk about indexes"],
        ]]
        #expect(GeminiLiveSession.hasFinalizedTranscription(event))
    }

    /// This is the whole point of the predicate: a finalized frame whose text the shared
    /// hallucination filter rejects is STILL a finalized frame — Gemini finished recognizing the
    /// utterance regardless of what `finalTranscript` goes on to do with the text. A caller using
    /// `finalTranscript(...) != nil` as its finalized-frame test cannot tell this case apart from "not
    /// a finalized frame at all," which is exactly the bug this predicate exists to let callers avoid.
    @Test func hasFinalizedTranscriptionIsTrueEvenWhenTheFilterWouldRejectTheText() {
        let thankYou: [String: Any] = ["serverContent": ["inputTranscription": ["text": "Thank you."]]]
        #expect(GeminiLiveSession.hasFinalizedTranscription(thankYou))
        #expect(GeminiLiveSession.finalTranscript(from: thankYou, speaker: .me) == nil)

        let punctuationOnly: [String: Any] = ["serverContent": ["inputTranscription": ["text": "."]]]
        #expect(GeminiLiveSession.hasFinalizedTranscription(punctuationOnly))
        #expect(GeminiLiveSession.finalTranscript(from: punctuationOnly, speaker: .me) == nil)
        #expect(GeminiLiveSession.finalTranscript(from: punctuationOnly, speaker: .them) == nil)
    }

    @Test func hasFinalizedTranscriptionIsFalseForAnInterimOnlyFrame() {
        let event: [String: Any] = ["serverContent": [
            "interimInputTranscription": ["text": "let's talk about ind"],
        ]]
        #expect(!GeminiLiveSession.hasFinalizedTranscription(event))
    }

    @Test func hasFinalizedTranscriptionIsFalseWithoutServerContent() {
        #expect(!GeminiLiveSession.hasFinalizedTranscription(["setupComplete": [String: Any]()]))
        #expect(!GeminiLiveSession.hasFinalizedTranscription([:]))
    }

    /// Real frame shape from a live capture: `voiceActivity` is a TOP-LEVEL key, a sibling of
    /// `serverContent` (which the server sends empty alongside it), not nested inside it.
    @Test func voiceActivityStartFrameIsAStart() {
        let event: [String: Any] = [
            "voiceActivity": ["type": "ACTIVITY_START", "audioOffset": "0.280s"],
            "serverContent": [String: Any](),
        ]
        #expect(GeminiLiveSession.isVoiceActivityStart(event))
    }

    /// The end marker must NOT read as a start — it is not a substitute finalization signal, and
    /// treating it as one would defeat the point of having a distinct start-only predicate.
    @Test func voiceActivityEndFrameIsNotAStart() {
        let event: [String: Any] = [
            "voiceActivity": ["type": "ACTIVITY_END", "audioOffset": "1.230s"],
        ]
        #expect(!GeminiLiveSession.isVoiceActivityStart(event))
    }

    @Test func frameWithoutVoiceActivityIsNotAStart() {
        #expect(!GeminiLiveSession.isVoiceActivityStart(["serverContent": [String: Any]()]))
        #expect(!GeminiLiveSession.isVoiceActivityStart([:]))
    }

    /// A malformed or unexpected `type` value must stay false rather than being treated as a start.
    @Test func voiceActivityWithUnexpectedTypeIsNotAStart() {
        #expect(!GeminiLiveSession.isVoiceActivityStart(["voiceActivity": ["type": "SOMETHING_ELSE"]]))
        #expect(!GeminiLiveSession.isVoiceActivityStart(["voiceActivity": [String: Any]()]))
    }

    /// Real frame shape: `goAway` is a TOP-LEVEL key, a sibling of `serverContent`, carrying the
    /// protobuf-`Duration`-encoded `timeLeft`.
    @Test func goAwayFrameIsDetected() {
        let event: [String: Any] = ["goAway": ["timeLeft": "9.5s"]]
        #expect(GeminiLiveSession.isGoAway(event))
    }

    /// Every other frame kind — setup acknowledgement, finalized/interim transcription, voice
    /// activity, or an empty object — must not read as `goAway`.
    @Test func otherFrameKindsAreNotGoAway() {
        #expect(!GeminiLiveSession.isGoAway(["setupComplete": [String: Any]()]))
        #expect(!GeminiLiveSession.isGoAway(["serverContent": ["inputTranscription": ["text": "hi"]]]))
        #expect(!GeminiLiveSession.isGoAway(["voiceActivity": ["type": "ACTIVITY_START"]]))
        #expect(!GeminiLiveSession.isGoAway([:]))
    }

    /// A malformed `goAway` (wrong value type, or none at all) must not crash and must read as absent.
    @Test func malformedGoAwayDoesNotCrash() {
        #expect(!GeminiLiveSession.isGoAway(["goAway": "not an object"]))
        #expect(!GeminiLiveSession.isGoAway(["goAway": NSNull()]))
        #expect(GeminiLiveSession.isGoAway(["goAway": [String: Any]()]))  // present, even if empty
    }

    @Test func goAwayTimeLeftParsesTheProtobufDurationString() {
        #expect(GeminiLiveSession.goAwayTimeLeft(["goAway": ["timeLeft": "9.5s"]]) == 9.5)
        #expect(GeminiLiveSession.goAwayTimeLeft(["goAway": ["timeLeft": "3s"]]) == 3.0)
    }

    /// Missing `goAway`, a missing/non-string `timeLeft`, or a non-numeric/unsuffixed value must all
    /// read as `nil` rather than crashing or returning a bogus number, so the caller falls back to its
    /// own fixed grace-period cap.
    @Test func goAwayTimeLeftIsNilForMissingOrMalformedValues() {
        #expect(GeminiLiveSession.goAwayTimeLeft([:]) == nil)
        #expect(GeminiLiveSession.goAwayTimeLeft(["goAway": [String: Any]()]) == nil)
        #expect(GeminiLiveSession.goAwayTimeLeft(["goAway": ["timeLeft": 9.5]]) == nil)
        #expect(GeminiLiveSession.goAwayTimeLeft(["goAway": ["timeLeft": "soon"]]) == nil)
        #expect(GeminiLiveSession.goAwayTimeLeft(["goAway": ["timeLeft": "9.5"]]) == nil)  // no "s" suffix
    }
}
