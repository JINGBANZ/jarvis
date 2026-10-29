import Foundation

public struct TranscriptionSetupAcceptance: Codable, Equatable, Sendable {
    public enum Confirmation: String, Codable, Sendable {
        case effectiveConfiguration
        case setupAcknowledged
        /// Deepgram sends no setup reply; its settings are query parameters on the accepted upgrade.
        case connectionOpened
        case localPreparation
    }

    public let target: TranscriptionTarget
    public let expectation: TranscriptionLanguageExpectation
    public let confirmation: Confirmation

    public init(target: TranscriptionTarget, expectation: TranscriptionLanguageExpectation) {
        self.target = target
        self.expectation = expectation
        confirmation = target.confirmation
    }
}
