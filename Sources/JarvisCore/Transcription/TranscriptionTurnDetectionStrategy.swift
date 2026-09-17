import Foundation

public enum TranscriptionTurnDetectionStrategy: Equatable, Sendable {
    case serverVAD
    case clientCommit
}
