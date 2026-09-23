import Foundation

public extension TranscriptionBenchmark {
    struct ExecutionStep: Codable, Equatable, Sendable {
        public let armID: String
        public let repetition: Int
    }

    static func vocabularySchedule(repetitions: Int) -> [ExecutionStep] {
        let arms = vocabularyArms
        return vocabularyPhrases.enumerated().flatMap { index, phrase in
            let pair = arms.filter { $0.phrase.id == phrase.id }
            return (1...repetitions).flatMap { repetition in
                let ordered = (index + repetition).isMultiple(of: 2) ? Array(pair.reversed()) : pair
                return ordered.map { ExecutionStep(armID: $0.id, repetition: repetition) }
            }
        }
    }
}
