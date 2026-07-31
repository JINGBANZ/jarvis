import Foundation

/// Immutable transcription choices captured at Start and shared by both speaker endpoints.
///
/// Keeping one value for the provider-specific settings prevents a Settings edit or reconnect from
/// splitting the mic and system-audio streams across different models, hints, or Apple locales.
public struct TranscriptionConfiguration: Equatable, Sendable {
    public let provider: TranscriptionProvider
    public let openAIModel: OpenAITranscriptionModel
    public let openAILanguageProfile: OpenAITranscriptionLanguageProfile
    public let appleSpeechLocaleIdentifier: String

    public init(
        provider: TranscriptionProvider,
        openAIModel: OpenAITranscriptionModel,
        openAILanguageProfile: OpenAITranscriptionLanguageProfile,
        appleSpeechLocaleIdentifier: String
    ) {
        self.provider = provider
        self.openAIModel = openAIModel
        self.openAILanguageProfile = openAILanguageProfile
        self.appleSpeechLocaleIdentifier = appleSpeechLocaleIdentifier
    }
}
