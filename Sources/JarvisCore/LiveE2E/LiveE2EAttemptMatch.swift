#if JARVIS_LIVE_E2E
public enum LiveE2EAttemptMatch: Sendable {
    case shortcut(CoachingShortcut)
    case speech(speaker: Speaker, transcriptBoundary: Int)

    public func matches(_ attempt: CoachingAttemptAuditEvent.Started) -> Bool {
        switch self {
        case .shortcut(let shortcut):
            attempt.reason == shortcut.triggerReason
        case .speech(let speaker, let boundary):
            !attempt.reason.isManual && attempt.transcriptLines.enumerated().contains { offset, line in
                attempt.transcriptStartIndex + offset >= boundary && line.speaker == speaker
            }
        }
    }
}
#endif
