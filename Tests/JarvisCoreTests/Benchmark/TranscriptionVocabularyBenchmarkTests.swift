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

    @Test(arguments: [3, 4])
    func pairedScheduleAlternatesOrderAndKeepsEveryRepetition(repetitions: Int) throws {
        let schedule = TranscriptionBenchmark.vocabularySchedule(repetitions: repetitions)
        #expect(schedule.count == 14 * repetitions)
        #expect(schedule.prefix(6).map { $0.armID.hasSuffix("baseline") } == [
            true, false, false, true, true, false,
        ])
        #expect(schedule.dropFirst(2 * repetitions).prefix(6).map { $0.armID.hasSuffix("baseline") } == [
            false, true, true, false, false, true,
        ])
        #expect(schedule.prefix(6).map(\.repetition) == [1, 1, 2, 2, 3, 3])
        for arm in TranscriptionBenchmark.vocabularyArms {
            #expect(schedule.filter { $0.armID == arm.id }.map(\.repetition) == Array(1...repetitions))
        }
        for index in stride(from: 0, to: schedule.count, by: 2) {
            let first = try #require(TranscriptionBenchmark.vocabularyArms.first {
                $0.id == schedule[index].armID
            })
            let second = try #require(TranscriptionBenchmark.vocabularyArms.first {
                $0.id == schedule[index + 1].armID
            })
            #expect(first.phrase == second.phrase)
            #expect(first.transcriptionPrompt != second.transcriptionPrompt)
        }
    }

    @Test func reportPreservesActualExecutionOrder() throws {
        let order = Array(TranscriptionBenchmark.vocabularySchedule(repetitions: 3).prefix(4))
        let summary = TranscriptionBenchmark.Summary(
            mode: "vocabulary", repetitionsPerArm: 3, arms: [], executionOrder: order)
        let decoded = try JSONDecoder().decode(
            TranscriptionBenchmark.Summary.self, from: summary.encodedJSON())
        #expect(decoded.executionOrder == order)
        let standard = TranscriptionBenchmark.Summary(mode: "standard", repetitionsPerArm: 3, arms: [])
        #expect(try JSONDecoder().decode(
            TranscriptionBenchmark.Summary.self, from: standard.encodedJSON()).executionOrder == nil)
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
