import Foundation

/// Why the coach loop woke up. Every trigger goes straight to the brain, which decides whether to
/// speak — including when the user addresses Jarvis by name (the model reads that from the transcript).
public enum TriggerReason: Sendable, Equatable {
    case turnEnd                              // server VAD: the speaker finished an utterance
    case silence(secondsQuiet: TimeInterval)  // no speech for the current backoff interval
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
            return "Trigger: the user just finished speaking. The session has been running for \(elapsed)s."
        case .silence(let secs):
            return "Trigger: the user has been silent for \(Int(secs))s. The session has been running for \(elapsed)s."
        }
    }
}
