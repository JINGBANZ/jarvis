import Foundation

/// Who turns a continuous OpenAI audio stream into committed transcription items.
public enum TranscriptionTurnDetectionStrategy: Equatable, Sendable {
    case serverVAD
    case clientCommit
}
