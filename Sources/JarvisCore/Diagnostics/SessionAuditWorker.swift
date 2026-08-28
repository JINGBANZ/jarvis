import Foundation
#if canImport(Darwin)
import Darwin
#else
import Synchronization
#endif

/// One bounded process-level worker for every file-backed session's evidence. Its mailbox carries
/// one versioned `SessionEvent` per occurrence; the typed producer ports — brain traffic, coaching
/// attempts, and agent-facing diagnostics — converge on it through their per-session handle. There
/// is deliberately no second worker per category (wiki/lean-coaching-core.md, "One Event, Two
/// Projections"): one mailbox, one lifecycle, one completeness record, one uniform loss contract.
///
/// The type keeps its Phase 0 name. The wiki's rule that renaming persisted artifacts is not a
/// completion requirement applies to the transport types too: a rename would touch every evaluator
/// and test call site without changing behavior.
///
/// The mailbox lock protects only retained in-memory values and counters. Parsing, redaction,
/// serialization, and file I/O run on the private serial queue after that lock is released.
final class SessionAuditWorker: @unchecked Sendable {
    struct Limits: Sendable {
        let maxEventCount: Int
        let maxRetainedBytes: Int

        /// Sized for the whole shared stack, not just audit records. Audit events arrive a handful
        /// per coaching attempt; agent-facing diagnostics arrive from 180-odd call sites and can
        /// burst during reconnects and teardown. A count bound tight enough for audit alone would
        /// turn ordinary diagnostic bursts into routine `queue_overflow`, making every busy session
        /// read as partial. Envelopes are small unless they carry a provider body, and the byte
        /// bound — unchanged — is what actually caps memory.
        static let production = Limits(
            maxEventCount: 4_096,
            maxRetainedBytes: 32 * 1024 * 1024)
    }

    /// Compiler-checked `Sendable`: mutable state is held only in atomic references.
    final class Session: Sendable {
        let id = UUID()
        let directory: URL
        /// The human-facing projection for this session's Activity occurrences, rendered on the
        /// worker so no producer pays for it. Absent when nothing is showing Activity.
        let activity: (any ActivityEventRecording)?
        let health = HealthCounters()
        private let sealed = AtomicCounter()
        private let opened = AtomicCounter()

        init(directory: URL, activity: (any ActivityEventRecording)?) {
            self.directory = directory
            self.activity = activity
        }

        var isSealed: Bool { sealed.load() > 0 }
        var isOpened: Bool { opened.load() > 0 }

        func seal() { sealed.mark() }
        func markOpened() { opened.mark() }
    }

    struct HealthSnapshot: Sendable, Equatable {
        let queueOverflow: Int
        let oversizeRecord: Int
        let openFailure: Int
        let writeFailure: Int
        let serializationFailure: Int

        var isComplete: Bool {
            queueOverflow == 0
                && oversizeRecord == 0
                && openFailure == 0
                && writeFailure == 0
                && serializationFailure == 0
        }
    }

    /// Compiler-checked `Sendable`: all counters are immutable atomic references.
    final class HealthCounters: Sendable {
        private let queueOverflow = AtomicCounter()
        private let oversizeRecord = AtomicCounter()
        private let openFailure = AtomicCounter()
        private let writeFailure = AtomicCounter()
        private let serializationFailure = AtomicCounter()

        func markQueueOverflow() { queueOverflow.increment() }
        func markOversizeRecord() { oversizeRecord.increment() }
        func markOpenFailure() { openFailure.increment() }
        func markWriteFailure() { writeFailure.increment() }
        func markSerializationFailure() { serializationFailure.increment() }

        var snapshot: HealthSnapshot {
            HealthSnapshot(
                queueOverflow: queueOverflow.load(),
                oversizeRecord: oversizeRecord.load(),
                openFailure: openFailure.load(),
                writeFailure: writeFailure.load(),
                serializationFailure: serializationFailure.load())
        }
    }

    /// `@unchecked Sendable`: every access uses an OS atomic primitive.
    private final class AtomicCounter: @unchecked Sendable {
        #if canImport(Darwin)
        private var storage: Int32 = 0

        func increment() {
            _ = OSAtomicIncrement32Barrier(&storage)
        }

        func mark() {
            _ = OSAtomicOr32Barrier(1, &storage)
        }

        func load() -> Int {
            Int(OSAtomicAdd32Barrier(0, &storage))
        }
        #else
        private let storage = Atomic<Int32>(0)

        func increment() {
            storage.wrappingAdd(1, ordering: .relaxed)
        }

        func mark() {
            storage.store(1, ordering: .relaxed)
        }

        func load() -> Int {
            Int(storage.load(ordering: .relaxed))
        }
        #endif
    }

    private enum Payload: Sendable {
        case open
        case event(SessionEvent)
        /// A diagnostic emitted with no live session handle, or after its handle was sealed. It
        /// reaches the asynchronous process log (Console) and stops there: guessing it into
        /// whichever session happens to be newest would be worse evidence than none.
        case processDiagnostic(DiagnosticAuditEvent)
        case close(
            forcePartial: Bool,
            completion: @Sendable (SessionAuditCloseResult) -> Void)
    }

    /// `session` is nil only for `.processDiagnostic`, which owns no session directory and
    /// therefore no health record.
    private struct Envelope: Sendable {
        let session: Session?
        let payload: Payload
        let retainedBytes: Int
    }

    /// A close that did not fit in the ring. This table is independently bounded, and a close becomes
    /// runnable only after every accepted envelope for its sealed session has finished.
    private struct DeferredClose: Sendable {
        let session: Session
        let forcePartial: Bool
        let completion: @Sendable (SessionAuditCloseResult) -> Void
    }

    private enum Work {
        case envelope(Envelope)
        case deferredClose(DeferredClose)
    }

    private enum EventEncodingError: Error {
        case mismatchedAttemptEvidence
    }

    static let shared = SessionAuditWorker(
        limits: .production,
        writer: SessionAuditFileWriter())

    private let limits: Limits
    private let writer: any SessionAuditWriting
    private let queue = DispatchQueue(label: "jarvis.sessionaudit", qos: .utility)
    private let mailboxLock = NSLock()
    private var ring: [Envelope?]
    private var readIndex = 0
    private var writeIndex = 0
    private var queuedCount = 0
    /// Includes the envelope currently executing on the worker.
    private var retainedCount = 0
    private var retainedBytes = 0
    private var drainScheduled = false
    private var unfinishedEnvelopeCounts: [UUID: Int] = [:]
    private var deferredCloses: [DeferredClose] = []
    private let timestampFormatter: DateFormatter
    /// Millisecond precision, matching what `jlog` wrote before the move: diagnostics are read to
    /// order events inside one turn, where whole seconds are too coarse.
    private let diagnosticTimestampFormatter: DateFormatter

    init(limits: Limits, writer: any SessionAuditWriting) {
        self.limits = Limits(
            maxEventCount: max(1, limits.maxEventCount),
            maxRetainedBytes: max(1, limits.maxRetainedBytes))
        self.writer = writer
        self.ring = Array(repeating: nil, count: max(1, limits.maxEventCount))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "HH:mm:ss"
        self.timestampFormatter = formatter
        let diagnosticFormatter = DateFormatter()
        diagnosticFormatter.locale = Locale(identifier: "en_US_POSIX")
        diagnosticFormatter.calendar = Calendar(identifier: .gregorian)
        diagnosticFormatter.dateFormat = "HH:mm:ss.SSS"
        self.diagnosticTimestampFormatter = diagnosticFormatter
    }

    func openSession(
        at directory: URL,
        activity: (any ActivityEventRecording)? = nil
    ) -> Session {
        let session = Session(directory: directory, activity: activity)
        _ = enqueue(Envelope(session: session, payload: .open, retainedBytes: 256))
        return session
    }

    /// Returns whether the mailbox accepted the envelope. A caller that holds a fallback — the
    /// process log, for diagnostics — uses it when this returns false, so a sealed handle or a full
    /// mailbox costs the session folder a record rather than silently costing the line entirely.
    @discardableResult
    func record(_ event: SessionEvent, for session: Session) -> Bool {
        enqueue(
            Envelope(
                session: session,
                payload: .event(event),
                retainedBytes: event.approximateRetainedBytes))
    }

    /// Admit a diagnostic that belongs to no live session. Bounded by the same mailbox as every
    /// other category — it has no reserved capacity, and an overflow simply loses the line.
    func recordProcessDiagnostic(_ event: DiagnosticAuditEvent) {
        _ = enqueue(
            Envelope(
                session: nil,
                payload: .processDiagnostic(event),
                retainedBytes: event.approximateRetainedBytes))
    }

    func close(
        _ session: Session,
        forcePartial: Bool,
        completion: @escaping @Sendable (SessionAuditCloseResult) -> Void
    ) {
        let envelope = Envelope(
            session: session,
            payload: .close(forcePartial: forcePartial, completion: completion),
            retainedBytes: 256)
        var immediateCompletions: [@Sendable (SessionAuditCloseResult) -> Void] = []
        var shouldSchedule = false

        mailboxLock.lock()
        if canRetain(envelope) {
            retain(envelope)
        } else if deferredCloses.count < limits.maxEventCount {
            deferredCloses.append(DeferredClose(
                session: session,
                forcePartial: forcePartial,
                completion: completion))
        } else if unfinishedEnvelopeCounts[session.id] == nil {
            // No accepted work can mutate this session after the lock is released. Its existing
            // in-progress marker is a stable incomplete result, so no worker retention is needed.
            immediateCompletions.append(completion)
        } else if let readyIndex = deferredCloses.firstIndex(where: {
            unfinishedEnvelopeCounts[$0.session.id] == nil
        }) {
            // Preserve the close whose session still has accepted work. The evicted close is already
            // stable at in-progress and can report partial without risking an evaluator/file race.
            immediateCompletions.append(deferredCloses.remove(at: readyIndex).completion)
            deferredCloses.append(DeferredClose(
                session: session,
                forcePartial: forcePartial,
                completion: completion))
        } else {
            // With at most `maxEventCount` retained envelopes, a new session cannot be unfinished
            // when that many distinct deferred sessions are also unfinished.
            assertionFailure("bounded audit close table has no stable entry")
            immediateCompletions.append(completion)
        }
        if immediateCompletions.isEmpty && !drainScheduled {
            drainScheduled = true
            shouldSchedule = true
        }
        mailboxLock.unlock()

        immediateCompletions.forEach { $0(.partial) }
        if shouldSchedule {
            queue.async { [self] in drain() }
        }
    }

    private func enqueue(_ envelope: Envelope) -> Bool {
        mailboxLock.lock()
        if envelope.session?.isSealed == true {
            mailboxLock.unlock()
            return false
        }
        if envelope.retainedBytes > limits.maxRetainedBytes {
            // Publish the sticky loss before Close can acquire the mailbox and enter the ring.
            envelope.session?.health.markOversizeRecord()
            mailboxLock.unlock()
            return false
        }
        guard canRetain(envelope) else {
            // Publish the sticky loss before Close can acquire the mailbox and enter the ring.
            envelope.session?.health.markQueueOverflow()
            mailboxLock.unlock()
            return false
        }
        retain(envelope)
        let shouldSchedule = !drainScheduled
        if shouldSchedule { drainScheduled = true }
        mailboxLock.unlock()

        if shouldSchedule {
            queue.async { [self] in drain() }
        }
        return true
    }

    private func canRetain(_ envelope: Envelope) -> Bool {
        retainedCount < limits.maxEventCount
            && retainedBytes <= limits.maxRetainedBytes - envelope.retainedBytes
    }

    private func retain(_ envelope: Envelope) {
        ring[writeIndex] = envelope
        writeIndex = (writeIndex + 1) % ring.count
        queuedCount += 1
        retainedCount += 1
        retainedBytes += envelope.retainedBytes
        if let session = envelope.session {
            unfinishedEnvelopeCounts[session.id, default: 0] += 1
        }
    }

    private func drain() {
        while let work = takeNextWork() {
            switch work {
            case .envelope(let envelope):
                process(envelope)
                finish(envelope)
            case .deferredClose(let close):
                finalize(
                    close.session,
                    forcePartial: close.forcePartial,
                    completion: close.completion)
            }
        }
    }

    private func takeNextWork() -> Work? {
        mailboxLock.lock()
        defer { mailboxLock.unlock() }
        if let closeIndex = deferredCloses.firstIndex(where: {
            unfinishedEnvelopeCounts[$0.session.id] == nil
        }) {
            return .deferredClose(deferredCloses.remove(at: closeIndex))
        }
        guard queuedCount > 0 else {
            drainScheduled = false
            return nil
        }
        let envelope = ring[readIndex]
        ring[readIndex] = nil
        readIndex = (readIndex + 1) % ring.count
        queuedCount -= 1
        return envelope.map(Work.envelope)
    }

    private func finish(_ envelope: Envelope) {
        mailboxLock.lock()
        retainedCount -= 1
        retainedBytes -= envelope.retainedBytes
        if let sessionID = envelope.session?.id {
            if let unfinished = unfinishedEnvelopeCounts[sessionID], unfinished > 1 {
                unfinishedEnvelopeCounts[sessionID] = unfinished - 1
            } else {
                unfinishedEnvelopeCounts[sessionID] = nil
            }
        }
        mailboxLock.unlock()
    }

    private func process(_ envelope: Envelope) {
        switch envelope.payload {
        case .processDiagnostic(let event):
            writer.emitToConsole(event.message)
        case .open:
            guard let session = envelope.session else { return }
            _ = ensureOpen(session)
        case .event(let event):
            guard let session = envelope.session else { return }
            persist(event, session: session)
        case .close(let forcePartial, let completion):
            guard let session = envelope.session else { return }
            finalize(
                session,
                forcePartial: forcePartial,
                completion: completion)
        }
    }

    private func ensureOpen(_ session: Session) -> Bool {
        if session.isOpened { return true }
        do {
            try writer.openSession(
                at: session.directory,
                initialHealth: try healthData(
                    state: "in_progress", snapshot: session.health.snapshot))
            session.markOpened()
            return true
        } catch {
            session.health.markOpenFailure()
            return false
        }
    }

    /// Project one envelope onto the session folder. File choice per kind is a projection detail;
    /// the record schemas and filenames are the unchanged Phase 0 contract.
    private func persist(_ event: SessionEvent, session: Session) {
        switch event.detail {
        case .brainTraffic(let traffic):
            persistTraffic(traffic, session: session)
        case .coachingAttempt(let attempt):
            persistAttempt(attempt, session: session)
        case .diagnostic(let diagnostic):
            persistDiagnostic(diagnostic, session: session)
        case .activity(let activity):
            // Phase 2 stepping stone: the projection still owns Activity's own persistence. What
            // changed is that the producer no longer calls it — the worker does, off the coaching
            // path, from the same envelope that carries every other evidence category.
            session.activity?.record(activity.presentation, at: activity.date)
        }
    }

    /// Console first, then the session's `jarvis-debug.log`, so a file failure still leaves the line
    /// visible in Console — the same order `jlog` used when it did both on the caller.
    private func persistDiagnostic(_ event: DiagnosticAuditEvent, session: Session) {
        writer.emitToConsole(event.message)
        guard ensureOpen(session) else { return }
        let line = "\(diagnosticTimestampFormatter.string(from: event.date)) \(event.message)"
        do {
            try writer.append(
                Data(line.utf8),
                filename: FileSessionAudit.diagnosticFilename,
                in: session.directory)
        } catch {
            session.health.markWriteFailure()
        }
    }

    private func persistTraffic(_ event: BrainTrafficAuditEvent, session: Session) {
        guard ensureOpen(session) else { return }
        let data: Data
        do {
            data = try encodeTraffic(event)
        } catch {
            session.health.markSerializationFailure()
            return
        }
        do {
            try writer.append(
                data,
                filename: FileSessionAudit.brainTrafficFilename,
                in: session.directory)
        } catch {
            session.health.markWriteFailure()
        }
    }

    private func persistAttempt(_ event: CoachingAttemptAuditEvent, session: Session) {
        guard ensureOpen(session) else { return }
        let data: Data
        do {
            data = try encodeAttempt(event)
        } catch {
            session.health.markSerializationFailure()
            return
        }
        do {
            try writer.append(
                data,
                filename: FileSessionAudit.coachingAttemptsFilename,
                in: session.directory)
        } catch {
            session.health.markWriteFailure()
        }
    }

    private func finalize(
        _ session: Session,
        forcePartial: Bool,
        completion: @Sendable (SessionAuditCloseResult) -> Void
    ) {
        guard ensureOpen(session) else {
            completion(.partial)
            return
        }
        let snapshot = session.health.snapshot
        let result: SessionAuditCloseResult = forcePartial || !snapshot.isComplete
            ? .partial : .complete
        do {
            try writer.replaceHealth(
                try healthData(
                    state: result == .complete ? "complete" : "partial",
                    snapshot: snapshot),
                in: session.directory)
            completion(result)
        } catch {
            session.health.markWriteFailure()
            if result == .complete {
                do {
                    try writer.replaceHealth(
                        try healthData(
                            state: "partial", snapshot: session.health.snapshot),
                        in: session.directory)
                } catch {
                    session.health.markWriteFailure()
                }
            }
            completion(.partial)
        }
    }

    private func encodeTraffic(_ event: BrainTrafficAuditEvent) throws -> Data {
        var line: [String: Any] = [
            "audit_version": FileSessionAudit.formatVersion,
            "t": timestampFormatter.string(from: event.date),
            "tag": event.tag,
            "ms": event.latencyMs,
            "record_kind": event.kind.rawValue,
        ]
        line["status"] = event.status
        line["error"] = event.error
        if let phases = event.phases, !phases.isEmpty { line["phases"] = phases }
        if let context = event.requestContext {
            line["coach_attempt"] = [
                "id": context.attemptID,
                "trigger": context.trigger,
                "source_trigger": context.sourceTrigger,
                "phase": context.phase.rawValue,
                "sequence": context.sequence,
            ]
        }
        line["request"] = Self.redactingImages(Self.jsonValue(event.request))
        if let response = event.response { line["response"] = Self.jsonValue(response) }
        return try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
    }

    private func encodeAttempt(_ event: CoachingAttemptAuditEvent) throws -> Data {
        let object: [String: Any]
        switch event {
        case .started(let event):
            guard event.transcriptLines.count == event.classifications.count else {
                throw EventEncodingError.mismatchedAttemptEvidence
            }
            let sourceTrigger = CoachingRequestAttribution.triggerName(event.reason)
            let effectiveTrigger = event.wake == .pendingWork
                ? CoachingAttemptAuditEvent.Wake.pendingWork.rawValue
                : sourceTrigger
            let lines: [[String: Any]] = zip(
                event.transcriptLines, event.classifications).enumerated().map { offset, pair in
                    let (line, classification) = pair
                    let index = event.transcriptStartIndex + offset
                    return [
                        "index": index,
                        "speaker": line.speaker.rawValue,
                        "text": line.text,
                        "at": line.at,
                        "classification": classification.rawValue,
                        "brain_facing": event.brainFacingTranscriptIndices.contains(index),
                    ]
                }
            var started: [String: Any] = [
                "audit_version": FileSessionAudit.formatVersion,
                "event": "started",
                "attempt": event.attemptID,
                "t": timestampFormatter.string(from: event.date),
                "wake": event.wake.rawValue,
                "trigger": effectiveTrigger,
                "source_trigger": sourceTrigger,
                "provider": event.target.provider.rawValue,
                "model": event.target.modelID,
                "transcript": lines,
            ]
            if case .silence(let seconds) = event.reason {
                started["seconds_quiet"] = seconds
            }
            object = started
        case .finished(let event):
            object = [
                "audit_version": FileSessionAudit.formatVersion,
                "event": "finished",
                "attempt": event.attemptID,
                "t": timestampFormatter.string(from: event.date),
                "terminal": event.terminal.rawValue,
                "outcome": Self.outcomeName(event.outcome),
            ]
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func healthData(state: String, snapshot: HealthSnapshot) throws -> Data {
        let object: [String: Any] = [
            "version": FileSessionAudit.formatVersion,
            "state": state,
            "queue_overflow": snapshot.queueOverflow,
            "oversize_record": snapshot.oversizeRecord,
            "open_failure": snapshot.openFailure,
            "write_failure": snapshot.writeFailure,
            "serialization_failure": snapshot.serializationFailure,
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func jsonValue(_ data: Data) -> Any {
        (try? JSONSerialization.jsonObject(with: data))
            ?? (String(data: data, encoding: .utf8) ?? "")
    }

    static func redactingImages(_ value: Any) -> Any {
        if let string = value as? String {
            guard string.hasPrefix("data:image/") else { return string }
            return "[base64 image omitted — \(string.count / 1024) KB; the pixels are saved as shot-N.jpg in this session directory]"
        }
        if let array = value as? [Any] {
            return array.map { redactingImages($0) }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues { redactingImages($0) }
        }
        return value
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
}
