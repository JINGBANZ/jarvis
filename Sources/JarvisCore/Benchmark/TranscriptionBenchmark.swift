import Foundation

// Design: wiki/transcription-benchmark.md
public enum TranscriptionBenchmark {
    public static let schemaVersion = 2
    public static let retainedRunCount = 10

    public enum Language: String, Codable, CaseIterable, Sendable {
        case english
        case mandarin
        case bilingual
    }

    /// Fixed cases, unlike the production language list, so schema-version-1 result files stay
    /// decodable.
    public enum LanguageProfile: String, Codable, Sendable {
        case automatic
        case english
        case mandarinChinese = "mandarin-chinese"
        case englishAndMandarinChinese = "english-and-mandarin-chinese"

        public var expectedLanguages: [TranscriptionLanguage] {
            switch self {
            case .automatic: []
            case .english: [.english]
            case .mandarinChinese: [.mandarinChinese]
            case .englishAndMandarinChinese: [.english, .mandarinChinese]
            }
        }
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

    /// Fixed, non-user input. Only each fixture's hash is persisted.
    public static let phrases: [Phrase] = standardPhrases + [followUpPhrase] + languageControlPhrases

    public static let languageControlPhrases: [Phrase] = [
        .init(id: "english-acknowledgement", language: .english, text: "Okay.", voice: "Samantha"),
        .init(id: "mandarin-acknowledgement", language: .mandarin, text: "好的。", voice: "Tingting"),
        .init(id: "silence", language: .bilingual, text: "", voice: ""),
        .init(id: "noise", language: .bilingual, text: "", voice: ""),
    ]

    /// One phrase per session, so language coverage stays comparable across providers.
    public static let standardPhrases: [Phrase] = [
        englishPhrase,
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

    static let englishPhrase = Phrase(
        id: "english-technical",
        language: .english,
        text: "The actor preserves ordered audio while the socket reconnects.",
        voice: "Samantha")

    /// The second turn of the turns matrix. Wording shares no phrasing with `englishPhrase` so a
    /// repeated first turn cannot be scored as this one.
    static let followUpPhrase = Phrase(
        id: "english-followup",
        language: .english,
        text: "Then the coach waits until the speaker finishes another sentence.",
        voice: "Samantha")

    public struct Arm: Codable, Equatable, Sendable {
        public let id: String
        public let target: TranscriptionTarget
        public var provider: TranscriptionProvider { target.provider }
        public let languageProfile: LanguageProfile?
        public let phrase: Phrase
        /// Only the turns matrix speaks twice in one session; every other arm leaves this empty.
        public let followUpPhrase: Phrase?

        public var orderedPhrases: [Phrase] {
            followUpPhrase.map { [phrase, $0] } ?? [phrase]
        }

        public init(
            id: String,
            target: TranscriptionTarget,
            languageProfile: LanguageProfile?,
            phrase: Phrase,
            followUpPhrase: Phrase? = nil
        ) {
            self.id = id
            self.target = target
            self.languageProfile = languageProfile
            self.phrase = phrase
            self.followUpPhrase = followUpPhrase
        }

        private enum CodingKeys: String, CodingKey {
            case id, target, languageProfile, phrase, followUpPhrase
            case provider, model, localeIdentifier
        }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            languageProfile = try values.decodeIfPresent(LanguageProfile.self, forKey: .languageProfile)
            phrase = try values.decode(Phrase.self, forKey: .phrase)
            followUpPhrase = try values.decodeIfPresent(Phrase.self, forKey: .followUpPhrase)
            if let target = try values.decodeIfPresent(TranscriptionTarget.self, forKey: .target) {
                self.target = target
            } else {
                // Retained benchmark runs use the schema-version-1 arm shape.
                switch try values.decode(TranscriptionProvider.self, forKey: .provider) {
                case .openAI:
                    target = .openAI(try values.decode(OpenAITranscriptionModel.self, forKey: .model))
                case .appleSpeech:
                    target = .appleSpeech(localeIdentifier: try values.decode(String.self, forKey: .localeIdentifier))
                case .gemini, .deepgram:
                    throw DecodingError.keyNotFound(CodingKeys.target,
                        .init(codingPath: decoder.codingPath, debugDescription: "Gemini and Deepgram arms require a target"))
                }
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(id, forKey: .id)
            try values.encode(target, forKey: .target)
            try values.encodeIfPresent(languageProfile, forKey: .languageProfile)
            try values.encode(phrase, forKey: .phrase)
            try values.encodeIfPresent(followUpPhrase, forKey: .followUpPhrase)
        }
    }

    public static var standardArms: [Arm] {
        let remote = TranscriptionTarget.remoteTargets.flatMap { target in
            standardPhrases.map { phrase in
                let profile: LanguageProfile = switch phrase.language {
                case .english: .english
                case .mandarin: .mandarinChinese
                case .bilingual: .englishAndMandarinChinese
                }
                return Arm(id: "\(target.provider.rawValue)--\(target.modelID!)--\(phrase.id)",
                    target: target, languageProfile: profile, phrase: phrase)
            }
        }
        let apple = standardPhrases.map { phrase in
            let locale = phrase.language == .english ? "en_US" : "zh_CN"
            return Arm(id: "apple-speech--\(locale)--\(phrase.id)",
                target: .appleSpeech(localeIdentifier: locale), languageProfile: nil, phrase: phrase)
        }
        return remote + apple
    }

    public static var turnArms: [Arm] {
        let remote = TranscriptionTarget.remoteTargets.flatMap { target in
            [Arm(id: "turns--\(target.provider.rawValue)--\(target.modelID!)",
                target: target, languageProfile: .english, phrase: englishPhrase,
                followUpPhrase: followUpPhrase),
             Arm(id: "turns--\(target.provider.rawValue)--\(target.modelID!)--bilingual",
                target: target, languageProfile: .englishAndMandarinChinese,
                phrase: standardPhrases[2], followUpPhrase: standardPhrases[1])]
        }
        let apple = Arm(id: "turns--apple-speech--en_US",
            target: .appleSpeech(localeIdentifier: "en_US"), languageProfile: nil,
            phrase: englishPhrase, followUpPhrase: followUpPhrase)
        return remote + [apple]
    }

    public static var languageArms: [Arm] {
        TranscriptionTarget.remoteTargets.flatMap { target in
            [LanguageProfile.automatic, .englishAndMandarinChinese].flatMap { profile in
                (standardPhrases + languageControlPhrases).map { phrase in
                    Arm(id: "languages--\(target.provider.rawValue)--\(target.modelID!)--\(profile.rawValue)--\(phrase.id)",
                        target: target, languageProfile: profile, phrase: phrase)
                }
            }
        }
    }
}
