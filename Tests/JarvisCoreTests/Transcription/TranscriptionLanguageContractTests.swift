import Foundation
import Testing
@testable import JarvisCore

@Suite struct TranscriptionLanguageContractTests {
    private let selections: [[TranscriptionLanguage]] = [
        [], [.english], [.mandarinChinese], [.english, .mandarinChinese],
    ]

    @Test func everyRemoteTargetHonorsEachSelectionForBothSpeakers() throws {
        for target in TranscriptionTarget.remoteTargets {
            for languages in selections {
                let configuration = target.configuration(expectedLanguages: languages)
                #expect(configuration.target == target)
                #expect(configuration.languageExpectation == .init(languages: languages))
                for speaker in [Speaker.me, .them] {
                    switch target {
                    case .openAI(let model):
                        let request = try wire(RealtimeSession.sessionUpdate(
                            model: model, speaker: speaker, expectedLanguages: languages,
                            keywords: ["Swift", "gRPC"]))
                        let settings = try openAISettings(request)
                        #expect(settings["model"] as? String == model.rawValue)
                        switch model {
                        case .gpt4oTranscribe:
                            #expect(settings["languages"] == nil)
                            #expect(settings["keywords"] == nil)
                            #expect(settings["delay"] == nil)
                            if languages.count == 2 {
                                let prompt = try #require(settings["prompt"] as? String)
                                #expect(prompt.contains("English and Mandarin"))
                                #expect(prompt.contains("switching languages within a sentence"))
                                #expect(prompt.contains("technical"))
                                #expect(prompt.hasPrefix(JarvisPrompts.Transcription.context(for: speaker)))
                                #expect(prompt.count < 600)
                            } else {
                                #expect(settings["prompt"] == nil)
                                #expect(settings["language"] as? String == languages.first?.singularHint)
                            }
                        case .gptTranscribe, .gptLiveTranscribe:
                            #expect(settings["language"] == nil)
                            #expect(settings["languages"] as? [String] == (languages.isEmpty ? nil : languages.map(\.multipleHint)))
                            #expect(settings["prompt"] as? String == JarvisPrompts.Transcription.context(for: speaker))
                            #expect(settings["keywords"] as? [String] == ["Swift", "gRPC"])
                        }
                    case .gemini(let model):
                        let request = try wire(GeminiLiveSession.setupMessage(
                            model: model, languages: languages, vocabulary: ["Swift", "gRPC"], mode: .verbatim))
                        let setup = try #require(request["setup"] as? [String: Any])
                        let settings = try #require(setup["inputAudioTranscription"] as? [String: Any])
                        #expect(settings["languageCodes"] as? [String] == languages.map(\.geminiHint))
                        #expect(settings["customVocabulary"] as? [String] == ["Swift", "gRPC"])
                        #expect(settings["prompt"] == nil)
                    case .deepgram, .appleSpeech:
                        Issue.record("remote target list contains \(target.provider.displayName)")
                    }
                }
            }
        }
    }

    @Test func acceptedOpenAISettingsAreRequiredForEverySelection() throws {
        for model in OpenAITranscriptionModel.allCases {
            for speaker in [Speaker.me, .them] {
                for languages in selections {
                    let requested = try wire(RealtimeSession.sessionUpdate(
                        model: model, speaker: speaker, expectedLanguages: languages))
                    var acknowledgement = requested
                    acknowledgement["type"] = "session.updated"
                    #expect(RealtimeSession.acceptsConfiguration(event: acknowledgement,
                        model: model, speaker: speaker, expectedLanguages: languages))
                    acknowledgement["type"] = "session.created"
                    #expect(!RealtimeSession.acceptsConfiguration(event: acknowledgement,
                        model: model, speaker: speaker, expectedLanguages: languages))
                }
            }
        }
    }

    @Test func changedOrMalformedOpenAISettingsCannotClaimReadiness() throws {
        for model in OpenAITranscriptionModel.allCases {
            for languages in selections {
                let request = try wire(RealtimeSession.sessionUpdate(model: model, expectedLanguages: languages))
                let settings = try openAISettings(request)
                var changes: [[String: Any]] = [
                    ["model": "another-model"], ["language": 123], ["languages": "en"], ["prompt": 123],
                ]
                if model == .gpt4oTranscribe, languages.count == 1 {
                    changes.append(["language": NSNull()])
                }
                if model != .gpt4oTranscribe, !languages.isEmpty {
                    changes.append(["languages": []])
                }
                if settings["prompt"] != nil {
                    changes.append(["prompt": ""])
                }
                for change in changes {
                    var changed = settings
                    changed.merge(change) { _, new in new }
                    let event: [String: Any] = ["type": "session.updated", "session": [
                        "type": "transcription", "audio": ["input": ["transcription": changed]],
                    ]]
                    #expect(!RealtimeSession.acceptsConfiguration(event: event,
                        model: model, speaker: .me, expectedLanguages: languages))
                }
            }
        }
    }

    @Test func capabilityAndConfirmationAreExplicitForEveryProvider() {
        #expect(Set(TranscriptionTarget.remoteTargets.map(\.provider)).union([.appleSpeech, .deepgram])
            == Set(TranscriptionProvider.allCases))
        let singleLanguageTargets: [TranscriptionTarget] = [.deepgram(.nova3), .appleSpeech(localeIdentifier: "zh_CN")]
        for target in TranscriptionTarget.remoteTargets + singleLanguageTargets {
            let acceptance = TranscriptionSetupAcceptance(target: target,
                expectation: target.configuration(expectedLanguages: []).languageExpectation)
            switch target {
            case .openAI(.gpt4oTranscribe):
                #expect(target.languageSupport == .singularHintAndContext)
                #expect(acceptance.confirmation == .effectiveConfiguration)
            case .openAI:
                #expect(target.languageSupport == .languageList)
                #expect(acceptance.confirmation == .effectiveConfiguration)
            case .gemini:
                #expect(target.languageSupport == .languageList)
                #expect(acceptance.confirmation == .setupAcknowledged)
            case .deepgram:
                #expect(target.languageSupport == .languageList)
                #expect(acceptance.expectation == .automatic)
                #expect(acceptance.confirmation == .connectionOpened)
            case .appleSpeech:
                #expect(target.languageSupport == .singleLocale)
                #expect(acceptance.expectation == .locale("zh_CN"))
                #expect(acceptance.confirmation == .localPreparation)
            }
        }
        #expect(GeminiLiveSession.isSetupComplete(["setupComplete": [:]]))
        for value: Any in [NSNull(), true, "accepted", []] {
            #expect(!GeminiLiveSession.isSetupComplete(["setupComplete": value]))
        }
    }

    @Test func aStartSnapshotSurvivesLaterPreferenceChangesOnEveryProvider() throws {
        let suite = "jarvis-language-contract-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = TranscriptionPreferences(defaults: defaults)
        for provider in TranscriptionProvider.allCases {
            preferences.provider = provider
            preferences.openAIExpectedLanguages = [.mandarinChinese, .english, .english]
            preferences.geminiExpectedLanguages = [.english, .mandarinChinese]
            preferences.appleSpeechLocaleIdentifier = "zh_CN"
            preferences.deepgramExpectedLanguages = [.mandarinChinese]
            let snapshot = preferences.configuration
            preferences.openAIExpectedLanguages = []
            preferences.geminiExpectedLanguages = []
            preferences.appleSpeechLocaleIdentifier = "en_US"
            preferences.deepgramExpectedLanguages = []
            #expect(snapshot.provider == provider)
            switch provider {
            case .appleSpeech:
                #expect(snapshot.languageExpectation == .locale("zh_CN"))
                #expect(preferences.configuration.languageExpectation == .locale("en_US"))
            case .deepgram:
                #expect(snapshot.languageExpectation == .languages([.mandarinChinese]))
                #expect(preferences.configuration.languageExpectation == .automatic)
            case .openAI, .gemini:
                #expect(snapshot.languageExpectation == .languages([.english, .mandarinChinese]))
                #expect(preferences.configuration.languageExpectation == .automatic)
            }
        }
    }

    private func wire(_ message: [String: Any]) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: message)) as? [String: Any])
    }

    private func openAISettings(_ message: [String: Any]) throws -> [String: Any] {
        let session = try #require(message["session"] as? [String: Any])
        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        return try #require(input["transcription"] as? [String: Any])
    }
}
