import Foundation

/// Why the coach loop woke up.
public enum TriggerReason: Sendable, Equatable {
    case turnEnd                              // semantic VAD: the speaker finished a thought
    case silence(secondsQuiet: TimeInterval)  // no speech for silenceTimeoutSeconds
}

/// Timing context handed to the model so it can tell "thinking" from "stuck".
public struct TriggerContext: Sendable {
    public let reason: TriggerReason
    public let secondsSinceLastSpeech: TimeInterval
    public let sessionElapsedSeconds: TimeInterval
    public init(reason: TriggerReason, secondsSinceLastSpeech: TimeInterval, sessionElapsedSeconds: TimeInterval) {
        self.reason = reason
        self.secondsSinceLastSpeech = secondsSinceLastSpeech
        self.sessionElapsedSeconds = sessionElapsedSeconds
    }

    /// A one-line natural-language summary appended to the user message.
    public var promptLine: String {
        let elapsed = Int(sessionElapsedSeconds)
        switch reason {
        case .turnEnd:
            return "Trigger: the user just finished speaking. They have been on this problem for \(elapsed)s."
        case .silence(let secs):
            return "Trigger: the user has been silent for \(Int(secs))s. They have been on this problem for \(elapsed)s."
        }
    }
}
