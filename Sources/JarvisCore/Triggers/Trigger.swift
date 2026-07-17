import Foundation

/// Why the coach loop woke up. Every trigger goes straight to the brain, which decides whether to
/// speak — including when the user addresses Jarvis by name (the model reads that from the transcript).
public enum TriggerReason: Sendable, Equatable {
    case turnEnd                              // server VAD: the speaker finished an utterance
    case silence(secondsQuiet: TimeInterval)  // no speech for the current backoff interval
    case screenChanged                        // visual monitor: meaningful change since the last capture
    case manualHint                           // user pressed the hint hotkey — capture + force a hint, one trip
}

/// Timing context handed to the model so it can tell "thinking" from "stuck".
public struct TriggerContext: Sendable {
    public let reason: TriggerReason
    public let sessionElapsedSeconds: TimeInterval
    public init(reason: TriggerReason, sessionElapsedSeconds: TimeInterval) {
        self.reason = reason
        self.sessionElapsedSeconds = sessionElapsedSeconds
    }

    /// The trigger note appended to the user message — or nil when the message already says it all.
    /// A turn-end adds nothing: the "New since last turn" block IS the signal, its [mm:ss] stamps
    /// carry the timing, and a boilerplate sentence on top would be committed to memory and re-billed
    /// on every later request. The notes that remain (silence, screen change, manual hint) open with
    /// the same [mm:ss] session stamp as transcript lines, so the model reads all timing in one idiom.
    public var promptLine: String? {
        let stamp = RollingTranscript.stamp(sessionElapsedSeconds)
        switch reason {
        case .turnEnd:
            return nil
        case .silence(let secs):
            return "[\(stamp)] (no speech for \(Self.durationPhrase(secs)))"
        case .screenChanged:
            return "[\(stamp)] (the screen changed since the last capture; use the attached fresh point-in-time screenshot)"
        case .manualHint:
            return "[\(stamp)] The user pressed the hint shortcut. They want your single most useful hint about what's on their screen right now — answer using the attached screenshot and the recent transcript."
        }
    }

    /// Human-readable duration ("45s", "2m 26s", "3h 30m"): a quiet stretch can run to hours, where
    /// a raw seconds count makes the model (and anyone reading the request log) do arithmetic.
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
