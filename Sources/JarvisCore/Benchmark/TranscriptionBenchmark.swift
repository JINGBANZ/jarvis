import Foundation

/// Foundation-only fixed input plan for the system-audio transcription benchmark. Audio capture,
/// playback, provider sessions, and reconnect control stay in the app shell.
public enum TranscriptionBenchmark {
    public static let schemaVersion = 1
    public static let retainedRunCount = 10

    public enum Language: String, Codable, CaseIterable, Sendable {
        case english
        case mandarin
        case bilingual
    }

    public struct Phrase: Codable, Equatable, Sendable {
        public let id: String
        public let language: Language
        public let text: String
        public let voice: String

        public init(id: String, language: Language, text: String, voice: String) {
            self.id = id
            self.language = language
            self.text = text
            self.voice = voice
        }
    }

    /// Fixed, non-user input. A runner synthesizes each phrase once and replays those exact bytes for
    /// every repetition, recording only the fixture hash in the persisted summary.
    public static let phrases: [Phrase] = [
        Phrase(
            id: "english-technical",
            language: .english,
            text: "The actor preserves ordered audio while the socket reconnects.",
            voice: "Samantha"),
        Phrase(
            id: "mandarin-technical",
            language: .mandarin,
            text: "系统在网络恢复后按顺序提交音频。",
            voice: "Tingting"),
        Phrase(
            id: "bilingual-technical",
            language: .bilingual,
            text: "请检查 Swift actor isolation，然后 commit the buffered audio exactly once.",
            voice: "Tingting"),
    ]

    public struct Arm: Codable, Equatable, Sendable {
        public let id: String
        public let provider: TranscriptionProvider
        public let model: OpenAITranscriptionModel?
        public let languageProfile: OpenAITranscriptionLanguageProfile?
        public let localeIdentifier: String?
        public let phrase: Phrase

        public init(
            id: String,
            provider: TranscriptionProvider,
            model: OpenAITranscriptionModel?,
            languageProfile: OpenAITranscriptionLanguageProfile?,
            localeIdentifier: String?,
            phrase: Phrase
        ) {
            self.id = id
            self.provider = provider
            self.model = model
            self.languageProfile = languageProfile
            self.localeIdentifier = localeIdentifier
            self.phrase = phrase
        }
    }

    public static var standardArms: [Arm] {
        let openAI = OpenAITranscriptionModel.allCases.flatMap { model in
            phrases.map { phrase in
                let profile: OpenAITranscriptionLanguageProfile = switch phrase.language {
                case .english: .english
                case .mandarin: .mandarinChinese
                case .bilingual: .englishAndMandarinChinese
                }
                return Arm(
                    id: "openai--\(model.rawValue)--\(phrase.id)",
                    provider: .openAI,
                    model: model,
                    languageProfile: profile,
                    localeIdentifier: nil,
                    phrase: phrase)
            }
        }
        let apple = phrases.map { phrase in
            let locale = phrase.language == .english ? "en_US" : "zh_CN"
            return Arm(
                id: "apple-speech--\(locale)--\(phrase.id)",
                provider: .appleSpeech,
                model: nil,
                languageProfile: nil,
                localeIdentifier: locale,
                phrase: phrase)
        }
        return openAI + apple
    }
}
