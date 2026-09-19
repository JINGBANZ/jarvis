import Foundation

public extension TranscriptionBenchmark {
    static let technicalContextPrompt = "Technical interview about streaming analytics: evict, deque, "
        + "min, max, timestamp, cutoff, amortized complexity, Big O. Preserve the spoken language."

    static let vocabularyPhrases: [Phrase] = phrases + [
        Phrase(
            id: "english-ordinary", language: .english,
            text: "Please move our meeting to Friday afternoon and send me the new address.",
            voice: "Samantha"),
        Phrase(
            id: "english-window", language: .english,
            text: "Evict expired events from the deque. Maintain the min and max for each window.",
            voice: "Samantha"),
        Phrase(
            id: "english-complexity", language: .english,
            text: "The timestamp equals the cutoff. Each event costs amortized O of one, not O of N.",
            voice: "Samantha"),
        Phrase(
            id: "english-fragments", language: .english,
            text: "The deque. Evict the oldest. Min and max. This timestamp. At the cutoff.",
            voice: "Samantha",
            synthesisText: "The deque. [[slnc 1200]] Evict the oldest. [[slnc 1200]] "
                + "Min and max. [[slnc 1200]] This timestamp. [[slnc 1200]] At the cutoff."),
    ]

    static var vocabularyArms: [Arm] {
        vocabularyPhrases.flatMap { phrase in
            let profile: LanguageProfile = switch phrase.language {
            case .english: .english
            case .mandarin: .mandarinChinese
            case .bilingual: .englishAndMandarinChinese
            }
            return [false, true].map { hinted in
                Arm(
                    id: "openai--gpt-4o-transcribe--\(phrase.id)--\(hinted ? "context" : "baseline")",
                    provider: .openAI,
                    model: .gpt4oTranscribe,
                    languageProfile: profile,
                    localeIdentifier: nil,
                    phrase: phrase,
                    transcriptionPrompt: hinted ? technicalContextPrompt : nil)
            }
        }
    }
}
