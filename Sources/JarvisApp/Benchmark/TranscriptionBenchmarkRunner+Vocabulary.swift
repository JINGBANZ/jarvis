import Foundation
import JarvisCore

extension TranscriptionBenchmarkRunner {
    func runVocabulary(fixtures: SyntheticSpeechFixtures) async throws -> TranscriptionBenchmark.Summary {
        let arms = TranscriptionBenchmark.vocabularyArms
        guard apiKey != nil else {
            return .init(
                mode: options.mode.rawValue,
                repetitionsPerArm: options.repetitions,
                arms: arms.map {
                    .init(arm: $0, repetitions: [], unavailableReason: Failure.apiKeyUnavailable.description)
                },
                executionOrder: [])
        }
        let armsByID = Dictionary(uniqueKeysWithValues: arms.map { ($0.id, $0) })
        var results: [String: [TranscriptionBenchmark.RepetitionResult]] = [:]
        var executionOrder: [TranscriptionBenchmark.ExecutionStep] = []
        for step in TranscriptionBenchmark.vocabularySchedule(repetitions: options.repetitions) {
            try Task.checkCancellation()
            guard !isAbortRequested else { throw Failure.benchmarkAborted }
            let arm = armsByID[step.armID]!
            TranscriptionBenchmarkFiles.writeProgress(
                phase: "vocabulary-repetition",
                detail: "\(arm.id) \(step.repetition)/\(options.repetitions)",
                to: options.outputDirectory)
            let result = await runRepetition(
                arm: arm,
                repetition: step.repetition,
                fixture: try fixtures.fixture(for: arm.phrase),
                silenceURL: fixtures.silenceURL,
                appleLocale: nil,
                quietPeriod: 5)
            executionOrder.append(step)
            results[arm.id, default: []].append(result)
            guard !isAbortRequested else { throw Failure.benchmarkAborted }
        }
        return .init(
            mode: options.mode.rawValue,
            repetitionsPerArm: options.repetitions,
            arms: arms.map { .init(arm: $0, repetitions: results[$0.id] ?? []) },
            executionOrder: executionOrder)
    }
}
