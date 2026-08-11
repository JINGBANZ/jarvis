import Foundation

/// Coach-facing, best-effort session-audit port.
///
/// Implementations must return immediately, must not throw, and must never invoke coaching callbacks.
public protocol CoachingAttemptAuditing: Sendable {
    func record(_ event: CoachingAttemptAuditEvent)
}

extension CoachingAttemptAuditing {
    func recordStarted(
        attemptID: Int,
        wake: CoachingAttemptAuditEvent.Wake,
        reason: TriggerReason,
        target: BrainTarget,
        transcriptStartIndex: Int,
        transcriptLines: [TranscriptLine],
        classifications: [CoachingAttemptAuditEvent.Classification],
        brainFacingTranscriptIndices: Set<Int>,
        at date: Date = Date()
    ) {
        record(.started(.init(
            attemptID: attemptID,
            wake: wake,
            reason: reason,
            target: target,
            transcriptStartIndex: transcriptStartIndex,
            transcriptLines: transcriptLines,
            classifications: classifications,
            brainFacingTranscriptIndices: brainFacingTranscriptIndices,
            date: date)))
    }

    func recordFinished(
        attemptID: Int,
        terminal: CoachingAttemptAuditEvent.TerminalAction,
        outcome: TurnOutcome,
        at date: Date = Date()
    ) {
        record(.finished(.init(
            attemptID: attemptID,
            terminal: terminal,
            outcome: outcome,
            date: date)))
    }
}
