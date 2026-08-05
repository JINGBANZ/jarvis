import Foundation

/// The service that turns the captured microphone and system-audio streams into text.
///
/// This choice is independent of `BrainProvider`: transcription supplies the conversation, while
/// the brain decides how to coach from it.
public enum TranscriptionProvider: String, CaseIterable, Codable, Sendable {
    case openAI = "openai"
    case appleSpeech = "apple-speech"

    public var displayName: String {
        switch self {
        case .openAI:
            "OpenAI"
        case .appleSpeech:
            "Apple Speech"
        }
    }

    public var requiresOpenAIAPIKey: Bool {
        self == .openAI
    }

    /// A key is needed when OpenAI supplies either the ears or any user-authorized brain target.
    public func requiresOpenAIAPIKey(for brainRoute: BrainRoute?) -> Bool {
        requiresOpenAIAPIKey
            || brainRoute?.targets.contains(where: { $0.provider == .openAI }) == true
    }
}
