import Foundation

public enum TriggerReason: Sendable, Equatable {
    case turnEnd
    case silence(secondsQuiet: TimeInterval)
    case manualHint
    case manualExplanation

    case manualCode

    public var isManual: Bool {
        self == .manualHint || self == .manualExplanation || self == .manualCode
    }
}

public struct TriggerContext: Sendable {
    public let reason: TriggerReason
    public let sessionElapsedSeconds: TimeInterval
    public init(reason: TriggerReason, sessionElapsedSeconds: TimeInterval) {
        self.reason = reason
        self.sessionElapsedSeconds = sessionElapsedSeconds
    }

    /// Nil for a turn-end: the new-speech block is the signal, and extra text would be re-billed on
    /// every later request.
    public var promptLine: String? {
        let stamp = RollingTranscript.stamp(sessionElapsedSeconds)
        switch reason {
        case .turnEnd:
            return nil
        case .silence(let secs):
            return JarvisPrompts.Coach.silenceTrigger(
                timestamp: stamp,
                duration: Self.durationPhrase(secs)
            )
        case .manualHint:
            return JarvisPrompts.Coach.manualHintTrigger(timestamp: stamp)
        case .manualExplanation:
            return JarvisPrompts.Coach.manualExplanationTrigger(timestamp: stamp)
        case .manualCode:
            return JarvisPrompts.Coach.manualCodeTrigger(timestamp: stamp)
        }
    }

    static func durationPhrase(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        if total < 60 { return "\(total)s" }
        if total < 3600 {
            let (m, s) = (total / 60, total % 60)
            return s == 0 ? "\(m)m" : "\(m)m \(s)s"
        }
        let (h, m) = (total / 3600, (total % 3600) / 60)
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}
