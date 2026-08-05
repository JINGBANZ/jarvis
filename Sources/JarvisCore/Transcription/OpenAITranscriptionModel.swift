import Foundation

/// The OpenAI speech-to-text model used by a transcription session.
///
/// GPT-4o remains the compatibility default. GPT Live is opt-in so the two models can be compared
/// across separate sessions without duplicating audio egress inside one session.
public enum OpenAITranscriptionModel: String, CaseIterable, Codable, Sendable {
    case gpt4oTranscribe = "gpt-4o-transcribe"
    case gptLiveTranscribe = "gpt-live-transcribe"

    public var displayName: String {
        switch self {
        case .gpt4oTranscribe:
            "GPT-4o Transcribe"
        case .gptLiveTranscribe:
            "GPT Live Transcribe"
        }
    }

    /// One capability source consumed by session configuration, capture, and commit coordination.
    public var turnDetectionStrategy: TranscriptionTurnDetectionStrategy {
        switch self {
        case .gpt4oTranscribe:
            .serverVAD
        case .gptLiveTranscribe:
            .clientCommit
        }
    }
}
