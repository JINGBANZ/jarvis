import Testing
import Foundation
@testable import JarvisCore

@Suite struct DeepgramLiveSessionTests {
    private func items(_ url: URL) -> [String: String] {
        let pairs = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // `language_hint` repeats; the first value is enough for single-valued assertions.
        return Dictionary(pairs.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    @Test func connectURLSelectsModelLanguageAndRawPCM() {
        let url = DeepgramLiveSession.connectURL(model: .nova3, languages: [.mandarinChinese], sampleRate: 16_000)
        #expect(url.scheme == "wss")
        #expect(url.host == "api.deepgram.com")
        #expect(url.path == "/v1/listen")
        let query = items(url)
        #expect(query["model"] == "nova-3")
        #expect(query["language"] == "zh")
        #expect(query["encoding"] == "linear16")
        #expect(query["sample_rate"] == "16000")
        #expect(query["interim_results"] == "true")
        #expect(query["utterance_end_ms"] == "1000")
    }

    @Test func englishUsesTheEnglishCode() {
        let url = DeepgramLiveSession.connectURL(model: .nova3, languages: [.english], sampleRate: 16_000)
        #expect(items(url)["language"] == "en")
    }

    @Test func severalLanguagesSelectMultilingualModeWithEachAsAHint() {
        let url = DeepgramLiveSession.connectURL(
            model: .nova3, languages: [.mandarinChinese, .english], sampleRate: 16_000)
        #expect(items(url)["language"] == "multi")
        let hints = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .filter { $0.name == "language_hint" }.compactMap(\.value)
        #expect(hints == ["en", "zh"])
    }

    @Test func noLanguageSelectionIsMultilingualWithoutHints() {
        let url = DeepgramLiveSession.connectURL(model: .nova3, languages: [], sampleRate: 16_000)
        #expect(items(url)["language"] == "multi")
        #expect(items(url)["language_hint"] == nil)
    }

    @Test func theKeyNeverEntersTheURL() {
        let url = DeepgramLiveSession.connectURL(model: .nova3, languages: [.english], sampleRate: 16_000)
        #expect(!url.absoluteString.contains("secret"))
        #expect(DeepgramLiveSession.authorizationValue(apiKey: "secret") == "Token secret")
    }

    @Test func parsesAFinalResultWithEndpointing() {
        let json = """
        {"type":"Results","is_final":true,"speech_final":true,
         "channel":{"alternatives":[{"transcript":"hello world","confidence":0.9}]}}
        """
        #expect(DeepgramLiveSession.parseEvent(Data(json.utf8))
            == .results(transcript: "hello world", isFinal: true, speechFinal: true))
    }

    @Test func parsesAnInterimResult() {
        let json = #"{"type":"Results","is_final":false,"channel":{"alternatives":[{"transcript":"hel"}]}}"#
        #expect(DeepgramLiveSession.parseEvent(Data(json.utf8))
            == .results(transcript: "hel", isFinal: false, speechFinal: false))
    }

    @Test func parsesControlEvents() {
        #expect(DeepgramLiveSession.parseEvent(Data(#"{"type":"UtteranceEnd","last_word_end":2.5}"#.utf8)) == .utteranceEnd)
        #expect(DeepgramLiveSession.parseEvent(Data(#"{"type":"SpeechStarted","timestamp":1.3}"#.utf8)) == .speechStarted)
        #expect(DeepgramLiveSession.parseEvent(Data(#"{"type":"Metadata","request_id":"x"}"#.utf8)) == .other)
        #expect(DeepgramLiveSession.parseEvent(Data(#"{"type":"Error","description":"bad"}"#.utf8)) == .error(description: "bad"))
    }

    @Test func dropsFramesThatAreNotJSONObjectsWithAType() {
        #expect(DeepgramLiveSession.parseEvent(Data("not json".utf8)) == nil)
        #expect(DeepgramLiveSession.parseEvent(Data(#"{"no":"type"}"#.utf8)) == nil)
    }

    @Test func joinsSegmentsWithSpacesInEnglish() {
        #expect(DeepgramLiveSession.joinedTranscript(
            ["Tell me about", "your last project."], speaker: .me)
            == "Tell me about your last project.")
    }

    @Test func closesGapsBetweenMandarinCharactersButKeepsEnglishWords() {
        #expect(DeepgramLiveSession.joinedTranscript(
            ["我 想 用 Kubernetes 部署 服务"], speaker: .me)
            == "我想用 Kubernetes 部署服务")
    }

    @Test func filtersSilenceHallucinationsForTheUser() {
        #expect(DeepgramLiveSession.joinedTranscript(["Thank you."], speaker: .me) == nil)
        #expect(DeepgramLiveSession.joinedTranscript([" ", ""], speaker: .them) == nil)
    }
}
