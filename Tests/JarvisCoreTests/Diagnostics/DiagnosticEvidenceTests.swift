import Foundation
import Testing
@testable import JarvisCore

/// Serialized because several cases park the worker's serial queue.
@Suite(.serialized) struct DiagnosticEvidenceTests {
    /// @unchecked: mutable state is guarded by `lock`, and the semaphores are thread-safe.
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

        func write(_ data: Data, filename: String, in directory: URL) throws {
            try backing.write(data, filename: filename, in: directory)
        }

        func emitToConsole(_ message: String) {
            lock.withLock { storedConsole.append(message) }
        }

        func releaseOpen() { openRelease.signal() }
    }

    /// The worker stays parked through the burst, so a caller doing the work hangs instead of
    /// failing.
    @Test func jlogPerformsNoConsoleOrFileWorkOnTheCaller() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = RecordingWriter(parkOpen: true)
        let evidence = FileSessionAudit(
            directory: directory,
            worker: SessionAuditWorker(limits: .production, writer: writer))
        wait(for: writer.openEntered)
        try await JarvisLogAttachmentLock.withExclusiveAttachment {
            JarvisLog.attach(to: evidence)
            defer { JarvisLog.detach() }

            for index in 0..<32 { jlog("parked-caller-diagnostic-\(index)") }

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
    }

    @Test func diagnosticsPersistToTheSessionDebugLogOwnerOnlyAndInOrder() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let evidence = FileSessionAudit(
            directory: directory,
            worker: SessionAuditWorker(limits: .production, writer: RecordingWriter()))

        admit("ordered-diagnostic-first", into: evidence)
        admit("ordered-diagnostic-second", into: evidence)
        #expect(await evidence.close() == .complete)

        let url = directory.appendingPathComponent(FileSessionAudit.diagnosticFilename)
        let lines = try debugLog(in: directory)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("ordered-diagnostic-first"))
        #expect(lines[1].hasSuffix("ordered-diagnostic-second"))
        // A 12-character "HH:mm:ss.SSS" stamp, then a space.
        #expect(lines[0].prefix(12).allSatisfy { $0.isNumber || $0 == ":" || $0 == "." })
        #expect(String(lines[0].dropFirst(12).prefix(1)) == " ")

        let mode = try FileManager.default.attributesOfItem(
            atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o600)
    }

    @Test func anUnattributedDiagnosticReachesTheProcessLogOnly() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = RecordingWriter()
        let worker = SessionAuditWorker(limits: .production, writer: writer)
        let evidence = FileSessionAudit(directory: directory, worker: worker)

        worker.recordProcessDiagnostic(
            DiagnosticAuditEvent(message: "unattributed-diagnostic"))
        // Closing drains the shared queue past the unattributed envelope.
        #expect(await evidence.close() == .complete)

        #expect(writer.console == ["unattributed-diagnostic"])
        #expect(try debugLog(in: directory).isEmpty)
    }

    @Test func aDiagnosticAfterCloseIsNeverGuessedIntoTheNextSession() async throws {
        let first = ActivityLogTests.tmp()
        let second = ActivityLogTests.tmp()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let worker = SessionAuditWorker(limits: .production, writer: RecordingWriter())
        let sessionA = FileSessionAudit(directory: first, worker: worker)
        try await JarvisLogAttachmentLock.withExclusiveAttachment {
            JarvisLog.attach(to: sessionA)
            defer { JarvisLog.detach() }

            jlog("belongs-to-session-a")
            #expect(await sessionA.close() == .complete)

            let sessionB = FileSessionAudit(directory: second, worker: worker)
            jlog("emitted-after-a-was-sealed")
            #expect(await sessionB.close() == .complete)

            let logA = try debugLog(in: first)
            #expect(logA.contains("belongs-to-session-a"))
            #expect(!logA.contains("emitted-after-a-was-sealed"))
            #expect(!(try debugLog(in: second)).contains("emitted-after-a-was-sealed"))
        }
    }

    @Test func aFullMailboxDropsOneDiagnosticAndKeepsAdmittingLaterOnes() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = RecordingWriter(parkOpen: true)
        let worker = SessionAuditWorker(
            limits: .init(maxEventCount: 2, maxRetainedBytes: 8_192),
            writer: writer)
        let evidence = FileSessionAudit(directory: directory, worker: worker)
        wait(for: writer.openEntered)

        admit("accepted-before-capacity", into: evidence)   // the session open holds the first slot
        admit("dropped-at-capacity", into: evidence)

        writer.releaseOpen()
        await waitForDebugLine("accepted-before-capacity", in: directory)
        admit("accepted-after-capacity", into: evidence)

        #expect(await evidence.close() == .partial)
        let log = try debugLog(in: directory)
        #expect(log.contains("accepted-before-capacity"))
        #expect(!log.contains("dropped-at-capacity"))
        #expect(log.contains("accepted-after-capacity"))
        #expect(try healthMarker(in: directory)["queue_overflow"] as? Int == 1)
    }

    @Test func anOversizeDiagnosticIsDroppedAndMarkedWithoutBlockingTheNext() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let evidence = FileSessionAudit(
            directory: directory,
            worker: SessionAuditWorker(
                limits: .init(maxEventCount: 8, maxRetainedBytes: 512),
                writer: RecordingWriter()))

        admit(String(repeating: "o", count: 1_024), into: evidence)
        admit("small-after-oversize", into: evidence)

        #expect(await evidence.close() == .partial)
        let log = try debugLog(in: directory)
        #expect(!log.contains(String(repeating: "o", count: 1_024)))
        #expect(log.contains("small-after-oversize"))
        #expect(try healthMarker(in: directory)["oversize_record"] as? Int == 1)
    }

    @Test func aFailedDiagnosticWriteMarksPartialAndLaterLinesStillPersist() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = RecordingWriter(failFirstDiagnosticAppend: true)
        let evidence = FileSessionAudit(
            directory: directory,
            worker: SessionAuditWorker(limits: .production, writer: writer))

        admit("write-fails-for-this-line", into: evidence)
        admit("write-succeeds-for-this-line", into: evidence)

        #expect(await evidence.close() == .partial)
        let log = try debugLog(in: directory)
        #expect(!log.contains("write-fails-for-this-line"))
        #expect(log.contains("write-succeeds-for-this-line"))
        #expect(writer.console.contains("write-fails-for-this-line"))
        #expect(try healthMarker(in: directory)["write_failure"] as? Int == 1)
    }

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

        admit("diagnostic-consuming-the-last-slot", into: evidence)
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

    /// Admits on the handle, not via `jlog`, so other suites' diagnostics can't skew exact counts.
    private func admit(_ message: String, into evidence: FileSessionAudit) {
        _ = evidence.recordDiagnostic(DiagnosticAuditEvent(message: message))
    }

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

    /// A progress barrier, not a latency check: once the line exists, the next admission has a
    /// slot.
    private func waitForDebugLine(_ needle: String, in directory: URL) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if (try? debugLog(in: directory))?.contains(needle) == true { return }
            await Task.yield()
        }
        #expect(Bool(false), "worker never persisted \(needle)")
    }
}
