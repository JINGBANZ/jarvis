import Foundation
import Testing
@testable import JarvisCore

/// Phase 1 of the lean coaching core: agent-facing diagnostics ride the one shared evidence
/// transport, and nothing about them runs on the caller.
///
/// Every case here is driven by deterministic fakes — a parked writer, a one-slot mailbox, a
/// byte-starved mailbox, an injected write failure, an explicit session rotation. None asserts on
/// elapsed wall-clock time.
///
/// Serialized because several cases park the worker's serial queue, and because `JarvisLog`'s
/// attachment is process-global.
@Suite(.serialized) struct DiagnosticEvidenceTests {
    /// Records what reached the Console edge and can park the worker on demand.
    private final class RecordingWriter: SessionAuditWriting, @unchecked Sendable {
        enum Failure: Error { case injectedAppend }

        let openEntered = DispatchSemaphore(value: 0)
        private let openRelease = DispatchSemaphore(value: 0)
        private let parkOpen: Bool
        private let failFirstDiagnosticAppend: Bool
        private let lock = NSLock()
        private let backing = SessionAuditFileWriter()
        private var storedConsole: [String] = []
        private var diagnosticAppends = 0

        init(parkOpen: Bool = false, failFirstDiagnosticAppend: Bool = false) {
            self.parkOpen = parkOpen
            self.failFirstDiagnosticAppend = failFirstDiagnosticAppend
        }

        var console: [String] { lock.withLock { storedConsole } }

        func openSession(at directory: URL, initialHealth: Data) throws {
            if parkOpen {
                openEntered.signal()
                openRelease.wait()
            }
            try backing.openSession(at: directory, initialHealth: initialHealth)
        }

        func append(_ data: Data, filename: String, in directory: URL) throws {
            if filename == FileSessionAudit.diagnosticFilename {
                let index = lock.withLock {
                    diagnosticAppends += 1
                    return diagnosticAppends
                }
                if failFirstDiagnosticAppend && index == 1 { throw Failure.injectedAppend }
            }
            try backing.append(data, filename: filename, in: directory)
        }

        func replaceHealth(_ data: Data, in directory: URL) throws {
            try backing.replaceHealth(data, in: directory)
        }

        func emitToConsole(_ message: String) {
            lock.withLock { storedConsole.append(message) }
        }

        func releaseOpen() { openRelease.signal() }
    }

    /// The core Phase 1 claim: `jlog` returns without the Console call, the file open, or the write
    /// having happened. The worker is parked in its first open for the whole emission burst, so a
    /// caller that still did any of that work would deadlock instead of failing an assertion.
    @Test func jlogPerformsNoConsoleOrFileWorkOnTheCaller() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = RecordingWriter(parkOpen: true)
        let evidence = FileSessionAudit(
            directory: directory,
            worker: SessionAuditWorker(limits: .production, writer: writer))
        wait(for: writer.openEntered)
        JarvisLog.attach(to: evidence)
        defer { JarvisLog.detach() }

        for index in 0..<32 { jlog("parked-caller-diagnostic-\(index)") }

        // The worker has not moved, so nothing reached Console and no debug log exists yet.
        #expect(writer.console.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(
                FileSessionAudit.diagnosticFilename).path))

        writer.releaseOpen()
        #expect(await evidence.close() == .complete)

        #expect(writer.console.contains("parked-caller-diagnostic-0"))
        #expect(writer.console.contains("parked-caller-diagnostic-31"))
        let log = try debugLog(in: directory)
        #expect(log.contains("parked-caller-diagnostic-0"))
        #expect(log.contains("parked-caller-diagnostic-31"))
    }

    /// The persisted artifact is unchanged by the move: same filename, owner-only mode, and one
    /// `HH:mm:ss.SSS`-stamped line per diagnostic, in admission order.
    @Test func diagnosticsPersistToTheSessionDebugLogOwnerOnlyAndInOrder() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let evidence = FileSessionAudit(
            directory: directory,
            worker: SessionAuditWorker(limits: .production, writer: RecordingWriter()))
        JarvisLog.attach(to: evidence)
        defer { JarvisLog.detach() }

        jlog("ordered-diagnostic-first")
        jlog("ordered-diagnostic-second")
        #expect(await evidence.close() == .complete)

        let url = directory.appendingPathComponent(FileSessionAudit.diagnosticFilename)
        let lines = try debugLog(in: directory)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("ordered-diagnostic-first"))
        #expect(lines[1].hasSuffix("ordered-diagnostic-second"))
        // "HH:mm:ss.SSS " — the millisecond stamp the agent-facing log has always carried.
        #expect(lines[0].prefix(12).allSatisfy { $0.isNumber || $0 == ":" || $0 == "." })
        #expect(String(lines[0].dropFirst(12).prefix(1)) == " ")

        let mode = try FileManager.default.attributesOfItem(
            atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o600)
    }

    /// A diagnostic emitted with no attachment reaches the asynchronous process log and stops
    /// there. It has no session, so it can never be written into one.
    @Test func anUnattributedDiagnosticReachesTheProcessLogOnly() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = RecordingWriter()
        let worker = SessionAuditWorker(limits: .production, writer: writer)
        let evidence = FileSessionAudit(directory: directory, worker: worker)

        worker.recordProcessDiagnostic(
            DiagnosticAuditEvent(message: "unattributed-diagnostic"))
        // Closing the live session drains the shared queue past the unattributed envelope.
        #expect(await evidence.close() == .complete)

        #expect(writer.console == ["unattributed-diagnostic"])
        #expect(try debugLog(in: directory).isEmpty)
    }

    /// Session rotation: a diagnostic emitted after session A is sealed must not land in A's log,
    /// and must not be guessed into the session that replaced it.
    @Test func aDiagnosticAfterCloseIsNeverGuessedIntoTheNextSession() async throws {
        let first = ActivityLogTests.tmp()
        let second = ActivityLogTests.tmp()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let worker = SessionAuditWorker(limits: .production, writer: RecordingWriter())
        let sessionA = FileSessionAudit(directory: first, worker: worker)
        JarvisLog.attach(to: sessionA)
        defer { JarvisLog.detach() }

        jlog("belongs-to-session-a")
        #expect(await sessionA.close() == .complete)

        // Session B exists and is live, but `JarvisLog` still points at the sealed handle A.
        let sessionB = FileSessionAudit(directory: second, worker: worker)
        jlog("emitted-after-a-was-sealed")
        #expect(await sessionB.close() == .complete)

        let logA = try debugLog(in: first)
        #expect(logA.contains("belongs-to-session-a"))
        #expect(!logA.contains("emitted-after-a-was-sealed"))
        #expect(!(try debugLog(in: second)).contains("emitted-after-a-was-sealed"))
    }

    /// Capacity loss is uniform and honest: the dropped line marks the session partial, and the
    /// next diagnostic is admitted on its own merits.
    @Test func aFullMailboxDropsOneDiagnosticAndKeepsAdmittingLaterOnes() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = RecordingWriter(parkOpen: true)
        let worker = SessionAuditWorker(
            limits: .init(maxEventCount: 2, maxRetainedBytes: 8_192),
            writer: writer)
        let evidence = FileSessionAudit(directory: directory, worker: worker)
        wait(for: writer.openEntered)
        JarvisLog.attach(to: evidence)
        defer { JarvisLog.detach() }

        jlog("accepted-before-capacity")   // fills the second of two slots
        jlog("dropped-at-capacity")

        writer.releaseOpen()
        await waitForDebugLine("accepted-before-capacity", in: directory)
        jlog("accepted-after-capacity")

        #expect(await evidence.close() == .partial)
        let log = try debugLog(in: directory)
        #expect(log.contains("accepted-before-capacity"))
        #expect(!log.contains("dropped-at-capacity"))
        #expect(log.contains("accepted-after-capacity"))
        #expect(try healthMarker(in: directory)["queue_overflow"] as? Int == 1)
    }

    /// An oversize diagnostic is refused outright and marks the session partial; the next one is
    /// unaffected.
    @Test func anOversizeDiagnosticIsDroppedAndMarkedWithoutBlockingTheNext() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let evidence = FileSessionAudit(
            directory: directory,
            worker: SessionAuditWorker(
                limits: .init(maxEventCount: 8, maxRetainedBytes: 512),
                writer: RecordingWriter()))
        JarvisLog.attach(to: evidence)
        defer { JarvisLog.detach() }

        jlog(String(repeating: "o", count: 1_024))
        jlog("small-after-oversize")

        #expect(await evidence.close() == .partial)
        let log = try debugLog(in: directory)
        #expect(!log.contains(String(repeating: "o", count: 1_024)))
        #expect(log.contains("small-after-oversize"))
        #expect(try healthMarker(in: directory)["oversize_record"] as? Int == 1)
    }

    /// A failed debug-log write marks the session partial and leaves later diagnostics working —
    /// the same best-effort contract every other evidence category is under.
    @Test func aFailedDiagnosticWriteMarksPartialAndLaterLinesStillPersist() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = RecordingWriter(failFirstDiagnosticAppend: true)
        let evidence = FileSessionAudit(
            directory: directory,
            worker: SessionAuditWorker(limits: .production, writer: writer))
        JarvisLog.attach(to: evidence)
        defer { JarvisLog.detach() }

        jlog("write-fails-for-this-line")
        jlog("write-succeeds-for-this-line")

        #expect(await evidence.close() == .partial)
        let log = try debugLog(in: directory)
        #expect(!log.contains("write-fails-for-this-line"))
        #expect(log.contains("write-succeeds-for-this-line"))
        // Console is ahead of the file on purpose, so a file failure still leaves the line visible.
        #expect(writer.console.contains("write-fails-for-this-line"))
        #expect(try healthMarker(in: directory)["write_failure"] as? Int == 1)
    }

    /// Diagnostics get no priority over audit records and grant none: a diagnostics-heavy session
    /// that overflows loses whichever records lost the race, and the coaching side is untouched.
    @Test func diagnosticsAndAuditRecordsShareOneUniformLossContract() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = RecordingWriter(parkOpen: true)
        let evidence = FileSessionAudit(
            directory: directory,
            worker: SessionAuditWorker(
                limits: .init(maxEventCount: 2, maxRetainedBytes: 65_536),
                writer: writer))
        wait(for: writer.openEntered)
        JarvisLog.attach(to: evidence)
        defer { JarvisLog.detach() }

        jlog("diagnostic-consuming-the-last-slot")
        evidence.record(
            tag: "audit-record-lost-to-a-diagnostics-flood",
            request: Data(#"{"model":"gpt-5.5"}"#.utf8),
            response: nil,
            status: nil,
            latencyMs: 1)

        writer.releaseOpen()
        #expect(await evidence.close() == .partial)
        let traffic = try String(
            contentsOf: directory.appendingPathComponent(
                FileSessionAudit.brainTrafficFilename),
            encoding: .utf8)
        #expect(!traffic.contains("audit-record-lost-to-a-diagnostics-flood"))
        #expect(try debugLog(in: directory).contains("diagnostic-consuming-the-last-slot"))
        #expect(try healthMarker(in: directory)["queue_overflow"] as? Int == 1)
    }

    // MARK: - helpers

    private func debugLog(in directory: URL) throws -> String {
        let url = directory.appendingPathComponent(FileSessionAudit.diagnosticFilename)
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func healthMarker(in directory: URL) throws -> [String: Any] {
        let data = try Data(
            contentsOf: directory.appendingPathComponent(FileSessionAudit.healthFilename))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func wait(for semaphore: DispatchSemaphore) {
        #expect(semaphore.wait(timeout: .now() + 10) == .success)
    }

    /// Progress barrier, not a latency assertion: yield until the worker has drained far enough for
    /// the named line to exist, so the next admission is known to face a free slot.
    private func waitForDebugLine(_ needle: String, in directory: URL) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if (try? debugLog(in: directory))?.contains(needle) == true { return }
            await Task.yield()
        }
        #expect(Bool(false), "worker never persisted \(needle)")
    }
}
