import Foundation
import Testing
@testable import JarvisCore

@Suite struct CoachReplyLanguageTests {
    private func configuration(
        languages: [OpenAITranscriptionLanguage] = [],
        provider: TranscriptionProvider = .openAI,
        locale: String = "en_US"
    ) -> TranscriptionConfiguration {
        .init(provider: provider, openAIModel: .gpt4oTranscribe,
              openAIExpectedLanguages: languages, appleSpeechLocaleIdentifier: locale)
    }

    @Test func onlyOneSelectionOverridesConversationalReplyLanguage() {
        #expect(configuration().coachingReplyLanguage == nil)
        #expect(configuration(languages: [.english, .mandarinChinese]).coachingReplyLanguage == nil)
        #expect(configuration(languages: [.english]).coachingReplyLanguage == "English")
        #expect(configuration(languages: [.mandarinChinese]).coachingReplyLanguage == "Mandarin")
        #expect(configuration(provider: .appleSpeech, locale: "fr_FR").coachingReplyLanguage == "French")
    }

    @Test func selectedReplyLanguageReachesTheBrainWithoutDroppingBilingualContextOrOutput() async {
        let lines = ["我们用 Kafka 做 message queue"]
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "tip", lines: lines)],
                  rawToolCalls: [RawToolCall(id: "tip", name: "speak",
                      argumentsJSON: "{\"lines\":[\"我们用 Kafka 做 message queue\"]}")])
        ])
        let target = BrainTarget(provider: .openAI,
                                 modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        let transcript = RollingTranscript()
        let overlay = FakeOverlay()
        let driver = CoachDriver(
            config: .default, transcript: transcript,
            route: .init(targets: [.init(target: target, brain: brain)]),
            screen: FakeScreen(), overlay: overlay, clock: ManualClock(now: 100),
            replyLanguage: configuration(languages: [.english]).coachingReplyLanguage)
        transcript.append(.init(speaker: .me, text: "Can you explain this design?", at: 1))
        transcript.append(.init(speaker: .them, text: "我们用 Kafka 做 message queue", at: 2))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        #expect(overlay.rendered == [lines])
        #expect(brain.calls.count == 1)
        #expect(brain.calls[0].contains {
            $0.role == .system && ($0.text ?? "").contains("For this session, reply in English")
        })
        #expect(brain.calls[0].contains {
            $0.role == .user && ($0.text ?? "").contains("我们用 Kafka 做 message queue")
        })
    }

    @Test(arguments: [Speaker.me, .them])
    func bothRecordingContextsDiscourageNonSpeechHallucinations(speaker: Speaker) throws {
        let payload = RealtimeSession.sessionUpdate(model: .gptLiveTranscribe, speaker: speaker)
        let session = try #require(payload["session"] as? [String: Any])
        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let transcription = try #require(input["transcription"] as? [String: Any])
        let prompt = try #require(transcription["prompt"] as? String)
        #expect(prompt.contains("Ignore music, singing and background noise"))
        #expect(prompt.contains("do not invent speech"))
        #expect(transcription["languages"] == nil)
    }
}
