import Foundation

/// Per-session provenance for the coaching decisions that sit around provider traffic. Provider
/// round trips alone cannot show a turn-end suppressed before a call, which finalized transcript
/// lines formed a request, or whether a later call was a screenshot continuation. This companion
/// JSONL makes those facts deterministic while keeping them inside the same owner-only session
/// directory as Activity and brain traffic.
///
/// Each attempt writes a `started` event followed by one `finished` event. The start owns the
/// trigger and indexed transcript snapshot; the finish owns the terminal action after route policy
/// has decided whether a provider failure exhausted the route. Actual provider calls carry the same
/// attempt id through `currentRequest` and are persisted by `BrainTrafficLog`.
///
/// Recording is enqueue-only on the coaching path. JSON serialization and disk writes run on the
/// private serial queue; session teardown calls `flush()` before exposing the session to evaluation.
///
/// `@unchecked Sendable`: all mutable state and disk writes are confined to the serial `queue`.
public final class CoachingAttemptLog: @unchecked Sendable {
    public static let filename = "coaching-attempts.jsonl"

    enum Wake: String, Sendable {
        case trigger
        case pendingWork = "pending_work"
    }

    enum RequestPhase: String, Sendable {
        case initial
        case captureScreenContinuation = "capture_screen_continuation"
    }

    enum TerminalAction: String, Sendable {
        case speak
        case staySilent = "stay_silent"
        case skippedFiller = "skipped_filler"
        case failure
        case exhaustion
        case cancelled
    }

    struct RequestContext: Sendable {
        let attemptID: Int
        let trigger: String
        let sourceTrigger: String
        let phase: RequestPhase
        let sequence: Int
    }

    /// Scoped around `makeConversation` and each `respond` call. It crosses async/actor hops but
    /// never leaks into the later summarizer request, whose traffic must remain unassociated.
    @TaskLocal static var currentRequest: RequestContext?

    private let queue = DispatchQueue(label: "jarvis.coachingattempts", qos: .utility)
    private var dir: URL?
    private let df: DateFormatter

    public init() {
        df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "HH:mm:ss"
    }

    /// Create the companion file immediately so a session with no coaching attempts is still
    /// explicit and owner-only rather than indistinguishable from a logging setup failure.
    public func enable(directory: URL) {
        queue.sync {
            dir = directory
            let url = directory.appendingPathComponent(Self.filename)
            FileManager.default.createFile(
                atPath: url.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600])
        }
    }

    func recordStarted(
        attemptID: Int,
        wake: Wake,
        reason: TriggerReason,
        target: BrainTarget,
        transcriptStartIndex: Int,
        transcriptLines: [TranscriptLine],
        classifications: [TurnSubstance.Classification],
        brainFacingTranscriptIndices: Set<Int>,
        at date: Date = Date()
    ) {
        precondition(transcriptLines.count == classifications.count)
        queue.async { [self] in
            let sourceTrigger = Self.triggerName(reason)
            let effectiveTrigger = wake == .pendingWork ? Wake.pendingWork.rawValue : sourceTrigger
            let lines: [[String: Any]] = zip(transcriptLines, classifications).enumerated().map {
                offset, pair in
                let (line, classification) = pair
                let index = transcriptStartIndex + offset
                return [
                    "index": index,
                    "speaker": line.speaker.rawValue,
                    "text": line.text,
                    "at": line.at,
                    "classification": classification.rawValue,
                    // This is the actual request-selection fact, deliberately independent from the
                    // diagnostic classification so a future gate regression remains observable.
                    "brain_facing": brainFacingTranscriptIndices.contains(index),
                ]
            }
            var event: [String: Any] = [
                "event": "started",
                "attempt": attemptID,
                "t": timestamp(date),
                "wake": wake.rawValue,
                "trigger": effectiveTrigger,
                "source_trigger": sourceTrigger,
                "provider": target.provider.rawValue,
                "model": target.modelID,
                "transcript": lines,
            ]
            if case .silence(let seconds) = reason {
                event["seconds_quiet"] = seconds
            }
            append(event)
        }
    }

    func recordFinished(
        attemptID: Int,
        terminal: TerminalAction,
        outcome: TurnOutcome,
        at date: Date = Date()
    ) {
        queue.async { [self] in
            append([
                "event": "finished",
                "attempt": attemptID,
                "t": timestamp(date),
                "terminal": terminal.rawValue,
                "outcome": Self.outcomeName(outcome),
            ])
        }
    }

    /// Wait until every event enqueued before this call is durable. This belongs at session
    /// teardown/evaluation boundaries, never in front of a coaching request.
    public func flush() {
        queue.sync {}
    }

    static func requestContext(
        attemptID: Int,
        wake: Wake,
        reason: TriggerReason,
        phase: RequestPhase,
        sequence: Int
    ) -> RequestContext {
        let source = triggerName(reason)
        return RequestContext(
            attemptID: attemptID,
            trigger: wake == .pendingWork ? Wake.pendingWork.rawValue : source,
            sourceTrigger: source,
            phase: phase,
            sequence: sequence)
    }

    private static func triggerName(_ reason: TriggerReason) -> String {
        switch reason {
        case .turnEnd: "turn_end"
        case .silence: "silence"
        case .manualHint: "manual_hint"
        }
    }

    private static func outcomeName(_ outcome: TurnOutcome) -> String {
        switch outcome {
        case .spoke: "spoke"
        case .silentByModel: "silent_by_model"
        case .skippedFillerOnly: "skipped_filler_only"
        case .truncated: "truncated"
        case .busy: "busy"
        case .cancelled: "cancelled"
        case .brainError: "brain_error"
        case .exhausted: "tool_loop_exhausted"
        }
    }

    private func timestamp(_ date: Date) -> String {
        df.string(from: date)
    }

    /// Must run on `queue`.
    private func append(_ event: [String: Any]) {
        guard let dir,
              let data = try? JSONSerialization.data(withJSONObject: event)
        else { return }
        let url = dir.appendingPathComponent(Self.filename)
        guard let fh = try? FileHandle(forWritingTo: url) else { return }
        defer { try? fh.close() }
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: data)
        try? fh.write(contentsOf: Data([0x0A]))
    }
}
