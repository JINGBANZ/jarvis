import Foundation
#if canImport(Darwin)
import Darwin
#else
import Synchronization
#endif

/// One process-level worker for every file-backed session audit.
///
/// The fixed-size ring and byte budget bound retained evidence even when disk access parks forever.
/// Mailbox admission uses `NSLock.try()` and drops immediately on contention or pressure; the worker
/// never holds that lock while parsing JSON or touching a file.
final class SessionAuditWorker: @unchecked Sendable {
    struct Limits: Sendable {
        let maxEventCount: Int
        let maxRetainedBytes: Int

        static let production = Limits(
            maxEventCount: 256,
            maxRetainedBytes: 32 * 1024 * 1024)
    }

    struct RetainedSnapshot: Sendable, Equatable {
        let eventCount: Int
        let approximateBytes: Int
    }

    final class Session: @unchecked Sendable {
        let id = UUID()
        let directory: URL
        let health = HealthCounters()
        private let sealed = AtomicCounter()
        private let opened = AtomicCounter()
        private let persistenceDisabled = AtomicCounter()

        init(directory: URL) {
            self.directory = directory
        }

        var isSealed: Bool { sealed.load() > 0 }
        var isOpened: Bool { opened.load() > 0 }
        var isPersistenceDisabled: Bool { persistenceDisabled.load() > 0 }

        func seal() { sealed.mark() }
        func markOpened() { opened.mark() }
        func disablePersistence() { persistenceDisabled.mark() }
    }

    struct HealthSnapshot: Sendable, Equatable {
        let queueOverflow: Int
        let oversizeRecord: Int
        let openFailure: Int
        let writeFailure: Int
        let closeTimeout: Int
        let lateEvent: Int
        let serializationFailure: Int

        var isComplete: Bool {
            queueOverflow == 0
                && oversizeRecord == 0
                && openFailure == 0
                && writeFailure == 0
                && closeTimeout == 0
                && lateEvent == 0
                && serializationFailure == 0
        }
    }

    final class HealthCounters: @unchecked Sendable {
        private let queueOverflow = AtomicCounter()
        private let oversizeRecord = AtomicCounter()
        private let openFailure = AtomicCounter()
        private let writeFailure = AtomicCounter()
        private let closeTimeout = AtomicCounter()
        private let lateEvent = AtomicCounter()
        private let serializationFailure = AtomicCounter()

        func markQueueOverflow() { queueOverflow.increment() }
        func markOversizeRecord() { oversizeRecord.increment() }
        func markOpenFailure() { openFailure.increment() }
        func markWriteFailure() { writeFailure.increment() }
        func markCloseTimeout() { closeTimeout.increment() }
        func markLateEvent() { lateEvent.increment() }
        func markSerializationFailure() { serializationFailure.increment() }

        var snapshot: HealthSnapshot {
            HealthSnapshot(
                queueOverflow: queueOverflow.load(),
                oversizeRecord: oversizeRecord.load(),
                openFailure: openFailure.load(),
                writeFailure: writeFailure.load(),
                closeTimeout: closeTimeout.load(),
                lateEvent: lateEvent.load(),
                serializationFailure: serializationFailure.load())
        }
    }

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
        case traffic(BrainTrafficAuditEvent)
        case attempt(CoachingAttemptAuditEvent)
        case close(
            deadline: ContinuousClock.Instant,
            completion: @Sendable (SessionAuditCloseResult) -> Void)
    }

    private struct Envelope: Sendable {
        let session: Session
        let payload: Payload
        let retainedBytes: Int
    }

    private enum EventEncodingError: Error {
        case mismatchedAttemptEvidence
    }

    private enum Admission {
        /// Provider and coach callbacks must drop immediately if another ingress owns the ring.
        case bestEffortRecord
        /// App lifecycle may wait only for the in-memory ring lock, never for worker or disk work.
        case lifecycle
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
    /// Includes the event currently executing on the worker.
    private var retainedCount = 0
    private var retainedBytes = 0
    private var drainScheduled = false
    private let timestampFormatter: DateFormatter

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
    }

    func openSession(at directory: URL) -> Session {
        let session = Session(directory: directory)
        let accepted = enqueue(
            Envelope(session: session, payload: .open, retainedBytes: 256),
            allowingSealedSession: false,
            admission: .lifecycle)
        if !accepted { session.disablePersistence() }
        return session
    }

    func record(_ event: BrainTrafficAuditEvent, for session: Session) {
        guard !session.isPersistenceDisabled else { return }
        _ = enqueue(
            Envelope(
                session: session,
                payload: .traffic(event),
                retainedBytes: event.approximateRetainedBytes),
            allowingSealedSession: false,
            admission: .bestEffortRecord)
    }

    func record(_ event: CoachingAttemptAuditEvent, for session: Session) {
        guard !session.isPersistenceDisabled else { return }
        _ = enqueue(
            Envelope(
                session: session,
                payload: .attempt(event),
                retainedBytes: event.approximateRetainedBytes),
            allowingSealedSession: false,
            admission: .bestEffortRecord)
    }

    func close(
        _ session: Session,
        deadline: ContinuousClock.Instant,
        completion: @escaping @Sendable (SessionAuditCloseResult) -> Void
    ) -> Bool {
        let accepted = enqueue(
            Envelope(
                session: session,
                payload: .close(deadline: deadline, completion: completion),
                retainedBytes: 256),
            allowingSealedSession: true,
            admission: .lifecycle)
        if !accepted {
            // A full bounded ring must not strand lifecycle settlement. This barrier runs behind the
            // current drain on the same serial queue, after all earlier envelopes for the now-sealed
            // session, and installs the necessarily partial marker before signaling stability.
            queue.async { [self] in
                finalize(session, deadline: deadline, completion: completion)
            }
        }
        return accepted
    }

    func retainedSnapshot() -> RetainedSnapshot {
        mailboxLock.lock()
        defer { mailboxLock.unlock() }
        return RetainedSnapshot(
            eventCount: retainedCount,
            approximateBytes: retainedBytes)
    }

    private func enqueue(
        _ envelope: Envelope,
        allowingSealedSession: Bool,
        admission: Admission
    ) -> Bool {
        if envelope.retainedBytes > limits.maxRetainedBytes {
            envelope.session.health.markOversizeRecord()
            return false
        }
        switch admission {
        case .bestEffortRecord:
            guard mailboxLock.try() else {
                envelope.session.health.markQueueOverflow()
                return false
            }
        case .lifecycle:
            mailboxLock.lock()
        }

        if envelope.session.isSealed && !allowingSealedSession {
            mailboxLock.unlock()
            envelope.session.health.markLateEvent()
            return false
        }
        guard retainedCount < limits.maxEventCount,
              retainedBytes <= limits.maxRetainedBytes - envelope.retainedBytes
        else {
            mailboxLock.unlock()
            envelope.session.health.markQueueOverflow()
            return false
        }

        ring[writeIndex] = envelope
        writeIndex = (writeIndex + 1) % ring.count
        queuedCount += 1
        retainedCount += 1
        retainedBytes += envelope.retainedBytes
        let shouldSchedule = !drainScheduled
        if shouldSchedule { drainScheduled = true }
        mailboxLock.unlock()

        if shouldSchedule {
            queue.async { [self] in drain() }
        }
        return true
    }

    private func drain() {
        while let envelope = takeNext() {
            process(envelope)
            finish(envelope)
        }
    }

    private func takeNext() -> Envelope? {
        mailboxLock.lock()
        defer { mailboxLock.unlock() }
        guard queuedCount > 0 else {
            drainScheduled = false
            return nil
        }
        let envelope = ring[readIndex]
        ring[readIndex] = nil
        readIndex = (readIndex + 1) % ring.count
        queuedCount -= 1
        return envelope
    }

    private func finish(_ envelope: Envelope) {
        mailboxLock.lock()
        retainedCount -= 1
        retainedBytes -= envelope.retainedBytes
        mailboxLock.unlock()
    }

    private func process(_ envelope: Envelope) {
        switch envelope.payload {
        case .open:
            open(envelope.session)
        case .traffic(let event):
            persistTraffic(event, session: envelope.session)
        case .attempt(let event):
            persistAttempt(event, session: envelope.session)
        case .close(let deadline, let completion):
            finalize(envelope.session, deadline: deadline, completion: completion)
        }
    }

    private func open(_ session: Session) {
        do {
            try writer.openSession(
                at: session.directory,
                initialHealth: try healthData(
                    state: "open", closed: false, snapshot: session.health.snapshot))
            session.markOpened()
        } catch {
            session.health.markOpenFailure()
            session.disablePersistence()
        }
    }

    private func persistTraffic(_ event: BrainTrafficAuditEvent, session: Session) {
        guard session.isOpened, !session.isPersistenceDisabled else {
            if !session.isOpened { session.health.markOpenFailure() }
            session.disablePersistence()
            return
        }
        let data: Data
        do {
            data = try encodeTraffic(event)
        } catch {
            session.health.markSerializationFailure()
            session.disablePersistence()
            return
        }
        do {
            try writer.append(
                data,
                filename: FileSessionAudit.brainTrafficFilename,
                in: session.directory)
        } catch {
            session.health.markWriteFailure()
            session.disablePersistence()
        }
    }

    private func persistAttempt(_ event: CoachingAttemptAuditEvent, session: Session) {
        guard session.isOpened, !session.isPersistenceDisabled else {
            if !session.isOpened { session.health.markOpenFailure() }
            session.disablePersistence()
            return
        }
        let data: Data
        do {
            data = try encodeAttempt(event)
        } catch {
            session.health.markSerializationFailure()
            session.disablePersistence()
            return
        }
        do {
            try writer.append(
                data,
                filename: FileSessionAudit.coachingAttemptsFilename,
                in: session.directory)
        } catch {
            session.health.markWriteFailure()
            session.disablePersistence()
        }
    }

    private func finalize(
        _ session: Session,
        deadline: ContinuousClock.Instant,
        completion: @Sendable (SessionAuditCloseResult) -> Void
    ) {
        if ContinuousClock.now >= deadline {
            session.health.markCloseTimeout()
        }
        var snapshot = session.health.snapshot
        if snapshot.isComplete {
            let completeSnapshot = snapshot
            do {
                let committed = try writer.replaceHealth(
                    try healthData(state: "complete", closed: true, snapshot: completeSnapshot),
                    in: session.directory
                ) {
                    ContinuousClock.now < deadline
                        && session.health.snapshot == completeSnapshot
                }
                if committed,
                   ContinuousClock.now < deadline,
                   session.health.snapshot == completeSnapshot {
                    completion(.complete)
                    return
                }
            } catch {
                session.health.markWriteFailure()
                completion(.partial)
                return
            }
        }

        if ContinuousClock.now >= deadline {
            session.health.markCloseTimeout()
        }
        snapshot = session.health.snapshot
        do {
            _ = try writer.replaceHealth(
                try healthData(state: "partial", closed: true, snapshot: snapshot),
                in: session.directory) { true }
        } catch {
            session.health.markWriteFailure()
        }
        completion(.partial)
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

    private func healthData(
        state: String,
        closed: Bool,
        snapshot: HealthSnapshot
    ) throws -> Data {
        let object: [String: Any] = [
            "version": FileSessionAudit.formatVersion,
            "state": state,
            "closed": closed,
            "queue_overflow": snapshot.queueOverflow,
            "oversize_record": snapshot.oversizeRecord,
            "open_failure": snapshot.openFailure,
            "write_failure": snapshot.writeFailure,
            "close_timeout": snapshot.closeTimeout,
            "late_event": snapshot.lateEvent,
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
