import Foundation
import Testing
@testable import JarvisCore

@Suite("Transcription vocabulary benchmark")
struct TranscriptionVocabularyBenchmarkTests {
    @Test func everyFixtureHasMatchedBaselineAndHintedArms() throws {
        let arms = TranscriptionBenchmark.vocabularyArms
        #expect(!arms.isEmpty)
        #expect(Set(arms.map(\.id)).count == arms.count)
        for model in [OpenAITranscriptionModel.gpt4oTranscribe] {
            for phrase in TranscriptionBenchmark.vocabularyPhrases {
                let pair = arms.filter { $0.model == model && $0.phrase == phrase }
                #expect(pair.count == 2)
                let baseline = try #require(pair.first { $0.transcriptionPrompt == nil })
                let hinted = try #require(pair.first { $0.transcriptionPrompt != nil })
                #expect(baseline.languageProfile == hinted.languageProfile)
                #expect(hinted.transcriptionPrompt == TranscriptionBenchmark.technicalContextPrompt)
            }
        }
        #expect(Set(arms.map(\.phrase.language)) == Set(TranscriptionBenchmark.Language.allCases))
    }

    @Test func promptExperimentOnlyChangesTranscriptionPrompt() throws {
        let baseline = RealtimeSession.sessionUpdate(model: .gpt4oTranscribe)
        let candidate = RealtimeSession.sessionUpdate(
            model: .gpt4oTranscribe, prompt: "Technical interview: evict, deque.")
        func transcription(_ update: [String: Any]) throws -> [String: Any] {
            let session = try #require(update["session"] as? [String: Any])
            let audio = try #require(session["audio"] as? [String: Any])
            let input = try #require(audio["input"] as? [String: Any])
            return try #require(input["transcription"] as? [String: Any])
        }
        let before = try transcription(baseline)
        var after = try transcription(candidate)
        #expect(before["prompt"] == nil)
        #expect(after.removeValue(forKey: "prompt") as? String == "Technical interview: evict, deque.")
        #expect(NSDictionary(dictionary: before).isEqual(to: after))
    }

    @Test func existingMatrixAndLegacyDecodingRemainStable() throws {
        #expect(TranscriptionBenchmark.standardArms.count == 12)
        let data = try JSONEncoder().encode(TranscriptionBenchmark.standardArms[0])
        let decoded = try JSONDecoder().decode(TranscriptionBenchmark.Arm.self, from: data)
        #expect(decoded.transcriptionPrompt == nil)
    }
}
