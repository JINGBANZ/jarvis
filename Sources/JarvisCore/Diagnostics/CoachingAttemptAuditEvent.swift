import Foundation

/// Attempt-level provenance around provider traffic.
public enum CoachingAttemptAuditEvent: Sendable {
    public enum Wake: String, Sendable {
        case trigger
        case pendingWork = "pending_work"
    }

    public enum RequestPhase: String, Sendable {
        case initial
        case captureScreenContinuation = "capture_screen_continuation"
        case searchPrepNotesContinuation = "search_prep_notes_continuation"
    }

    public enum TerminalAction: String, Sendable {
        case speak
        case staySilent = "stay_silent"
        case skippedFiller = "skipped_filler"
        case failure
        case exhaustion
        case cancelled
    }

    /// Audit-visible result of the conservative runtime substance gate.
    public enum Classification: String, Sendable {
        case substantive
        case knownFiller = "known_filler"
        case compositeFiller = "composite_filler"
        case empty

        var isSubstantive: Bool { self == .substantive }
    }

    public struct Started: Sendable {
        public let attemptID: Int
        public let wake: Wake
        public let reason: TriggerReason
        public let target: BrainTarget
        public let transcriptStartIndex: Int
        public let transcriptLines: [TranscriptLine]
        public let classifications: [Classification]
        public let brainFacingTranscriptIndices: Set<Int>
        public let date: Date

        var approximateRetainedBytes: Int {
            var bytes = 384 + classifications.count * 16
            for line in transcriptLines {
                let (sum, overflow) = bytes.addingReportingOverflow(
                    96 + line.text.utf8.count + line.speaker.rawValue.utf8.count)
                bytes = overflow ? .max : sum
            }
            return bytes
        }
    }

    public struct Finished: Sendable {
        public let attemptID: Int
        public let terminal: TerminalAction
        public let outcome: TurnOutcome
        public let date: Date
    }

    case started(Started)
    case finished(Finished)

    var approximateRetainedBytes: Int {
        switch self {
        case .started(let event): event.approximateRetainedBytes
        case .finished: 256
        }
    }
}
