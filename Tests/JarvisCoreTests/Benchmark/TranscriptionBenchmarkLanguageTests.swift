import Foundation
import Testing
@testable import JarvisCore

@Suite struct TranscriptionBenchmarkLanguageTests {
    @Test func theSameFixturesCompareAutomaticAndBilingualForEveryRemoteTarget() {
        for target in TranscriptionTarget.remoteTargets {
            let arms = TranscriptionBenchmark.languageArms.filter { $0.target == target }
            let automatic = arms.filter { $0.languageProfile == .automatic }
            let bilingual = arms.filter { $0.languageProfile == .englishAndMandarinChinese }
            #expect(automatic.map(\.phrase) == bilingual.map(\.phrase))
            #expect(automatic.count == 7)
            #expect(Set(automatic.map(\.phrase.id)).isSuperset(of: ["silence", "noise",
                "english-acknowledgement", "mandarin-acknowledgement", "bilingual-technical"]))
        }
    }

    @Test func evidenceRetainsProviderConfirmationAndUsage() throws {
        let arm = TranscriptionBenchmark.languageArms.first!
        let acceptance = TranscriptionSetupAcceptance(target: arm.target, expectation: .automatic)
        let usage = try #require(TranscriptionUsage.openAI(from: ["usage": [
            "input_tokens": 10, "output_tokens": 5, "total_tokens": 15,
        ]]))
        let result = TranscriptionBenchmark.evaluate(.init(arm: arm, repetition: 1,
            fixtureSHA256: "same-fixture", connectStartedAt: 1, speechEndedAt: 5, events: [
                .init(kind: .ready, provider: arm.provider.rawValue, speaker: "them", generation: 1,
                    observedAt: 2, setupAcceptance: acceptance),
                .init(kind: .providerFinal, provider: arm.provider.rawValue, speaker: "them", generation: 1,
                    observedAt: 6, usage: usage),
                .init(kind: .finalized, provider: arm.provider.rawValue, speaker: "them", generation: 1,
                    text: "Swift 中文 カナ 한글 مرحبا", observedAt: 6),
            ]))
        #expect(result.setupAcceptance == acceptance)
        #expect(result.reportedUsage == [usage])
        #expect(result.unexpectedScriptCharacterCount == 9)
        #expect(TranscriptionBenchmark.unexpectedScriptCharacterCount(in: "Swift 中文 résumé 123") == 0)
        let decoded = try JSONDecoder().decode(TranscriptionBenchmark.RepetitionResult.self,
            from: JSONEncoder().encode(result))
        #expect(decoded == result)
        #expect(TranscriptionUsage.gemini(from: ["usageMetadata": [
            "promptTokenCount": 10, "responseTokenCount": 5, "totalTokenCount": 15,
        ]]) == usage)
    }

    @Test func silenceIsNotScoredAsMissingSpeech() {
        let arm = TranscriptionBenchmark.languageArms.first { $0.phrase.id == "silence" }!
        let result = TranscriptionBenchmark.evaluate(.init(arm: arm, repetition: 1,
            fixtureSHA256: "silence-hash", connectStartedAt: 1, speechEndedAt: 5, events: []))
        #expect(!result.missing)
        #expect(result.normalizedCharacterErrorRate == nil)
        #expect(result.finalTexts.isEmpty)
    }
}
