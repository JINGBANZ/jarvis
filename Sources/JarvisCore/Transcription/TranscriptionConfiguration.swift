import Foundation

/// Immutable transcription choices captured at Start and shared by both speaker endpoints.
///
/// Keeping one value for the provider-specific settings prevents a Settings edit or reconnect from
/// splitting the mic and system-audio streams across different models, hints, or Apple locales.
public struct TranscriptionConfiguration: Equatable, Sendable {
    public let provider: TranscriptionProvider
    public let openAIModel: OpenAITranscriptionModel
    public let openAIExpectedLanguages: [OpenAITranscriptionLanguage]
    public let appleSpeechLocaleIdentifier: String

    public init(
        provider: TranscriptionProvider,
        openAIModel: OpenAITranscriptionModel,
        openAIExpectedLanguages: [OpenAITranscriptionLanguage],
        appleSpeechLocaleIdentifier: String
    ) {
        self.provider = provider
        self.openAIModel = openAIModel
        self.openAIExpectedLanguages = OpenAITranscriptionLanguage.canonicalizing(
            openAIExpectedLanguages)
        self.appleSpeechLocaleIdentifier = appleSpeechLocaleIdentifier
    }

    /// Apple owns result segmentation internally; OpenAI exposes an explicit turn strategy.
    public var turnDetectionStrategy: TranscriptionTurnDetectionStrategy? {
        provider == .openAI ? openAIModel.turnDetectionStrategy : nil
    }
}
