import Foundation

public enum OpenAITranscriptionModel: String, CaseIterable, Codable, Sendable {
    case gpt4oTranscribe = "gpt-4o-transcribe"
    case gptTranscribe = "gpt-transcribe"
    case gptLiveTranscribe = "gpt-live-transcribe"

    public var displayName: String {
        switch self {
        case .gpt4oTranscribe:
            "GPT-4o Transcribe"
        case .gptTranscribe:
            "GPT Transcribe"
        case .gptLiveTranscribe:
            "GPT Live Transcribe"
        }
    }

    public var turnDetectionStrategy: TranscriptionTurnDetectionStrategy {
        switch self {
        case .gpt4oTranscribe:
            .serverVAD
        case .gptTranscribe, .gptLiveTranscribe:
            .clientCommit
        }
    }
}
