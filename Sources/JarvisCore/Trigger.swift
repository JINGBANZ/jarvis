import Foundation

/// Why the coach loop woke up.
public enum TriggerReason: Sendable, Equatable {
    case turnEnd                              // server VAD: the speaker finished an utterance
    case silence(secondsQuiet: TimeInterval)  // no speech for silenceTimeoutSeconds
    case directAddress                        // the user addressed Jarvis by name — must reply

    /// True when the user spoke to Jarvis directly; such turns bypass the cooldown and force a reply.
    public var isDirectAddress: Bool {
        if case .directAddress = self { return true }
        return false
    }
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
        case .directAddress:
            return "Trigger: the user is speaking to you DIRECTLY and is waiting for a reply. You MUST respond now with the speak tool — a brief, helpful answer or question. They have been on this problem for \(elapsed)s."
        }
    }
}
