import Foundation
import Testing
@testable import JarvisCore

@Suite struct ActivityProjectionTests {
    @Test func theEnvelopeDerivesActivityKindTimingAndPresentation() {
        let occurred = Date(timeIntervalSince1970: 1_755_000_000)
        let event = SessionEvent(
            sessionID: UUID(),
            detail: .activity(ActivityAuditEvent(
                presentation: .tip(lines: ["one", "two"]),
                date: occurred)))

        #expect(event.kind == .activity)
        #expect(event.kind.rawValue == "activity")
        #expect(event.occurredAt == occurred)
        #expect(event.attemptID == nil)
        #expect(event.activityPresentation?.rendered.kind == .tip)
        #expect(event.activityPresentation?.rendered.message == "💬 one two")
    }

    @Test func nonActivityDetailsCarryNoHumanCopy() {
        let sessionID = UUID()
        let diagnostic = SessionEvent(
            sessionID: sessionID,
            detail: .diagnostic(DiagnosticAuditEvent(message: "Jarvis coach: 503 from provider")))
        #expect(diagnostic.activityPresentation == nil)

        let attempt = SessionEvent(
            sessionID: sessionID,
            detail: .coachingAttempt(.finished(.init(
                attemptID: 1, terminal: .speak, outcome: .spoke, date: Date()))))
        #expect(attempt.activityPresentation == nil)
    }

    @Test func theWorkerProjectsActivityOccurrencesOffTheProducer() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (projection, evidence) = ActivityLog.recordingSession(in: directory)
        defer { projection.disable() }

        let heardAt = Date(timeIntervalSince1970: 1_755_000_042)
        evidence.record(.heard(speaker: .them, text: "what's the tradeoff?"), at: heardAt)
        evidence.record(.tip(lines: ["name the tradeoff"]))
        #expect(await evidence.close() == .complete)

        let rows = projection.attach { _ in }.rows
        #expect(rows.count == 2)
        #expect(rows[0].contains("🗣 heard (them)"))
        #expect(rows[1].contains("💬 name the tradeoff"))
        let persisted = try String(
            contentsOf: directory.appendingPathComponent(ActivityLog.filename), encoding: .utf8)
        let first = try #require(
            JSONSerialization.jsonObject(
                with: Data(persisted.split(separator: "\n")[0].utf8)) as? [String: Any])
        #expect(first["o"] as? Double == heardAt.timeIntervalSince1970)
    }

    @Test func aSessionWithoutAnActivityProjectionStillRecordsEvidence() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let evidence = FileSessionAudit(
            directory: directory,
            worker: SessionAuditWorker(limits: .production, writer: SessionAuditFileWriter()))

        evidence.record(.stayedSilent)
        evidence.record(
            tag: "coach", request: Data(#"{"model":"gpt-5.5"}"#.utf8),
            response: nil, status: nil, latencyMs: 3)
        #expect(await evidence.close() == .complete)

        let traffic = try String(
            contentsOf: directory.appendingPathComponent(
                FileSessionAudit.brainTrafficFilename),
            encoding: .utf8)
        #expect(traffic.contains("\"tag\":\"coach\""))
    }

    @Test func kernelOccurrencesReachTheActivityWindowThroughTheSharedHandle() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (activityLog, evidence) = ActivityLog.recordingSession(in: directory)
        defer { activityLog.disable() }

        evidence.record(.manualHint(prompt: "unblock me"))
        evidence.record(.screenViewFailed)
        evidence.record(.tip(lines: ["say the number"]))
        #expect(await evidence.close() == .complete)

        let snapshot = activityLog.attach { _ in }
        #expect(snapshot.total == 3)
        let jsonl = try String(
            contentsOf: directory.appendingPathComponent(ActivityLog.filename), encoding: .utf8)
        #expect(jsonl.contains("⌨️ hint shortcut — unblock me"))
        #expect(jsonl.contains("👁 couldn't view your screen"))
        #expect(jsonl.contains("💬 say the number"))
        #expect(jsonl.contains("\"k\":\"manualHint\""))
        #expect(jsonl.contains("\"k\":\"tip\""))
        #expect(!jsonl.contains("audit_version"))
    }

    @Test func screenshotAttachmentsPersistOwnerOnlyInsideTheSessionDirectory() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (projection, evidence) = ActivityLog.recordingSession(in: directory)
        defer { projection.disable() }

        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        evidence.record(.screenViewed(imageBase64JPEG: jpeg.base64EncodedString()))
        evidence.record(.screenViewed(imageBase64JPEG: jpeg.base64EncodedString()))
        #expect(await evidence.close() == .complete)

        for name in ["shot-1.jpg", "shot-2.jpg"] {
            let url = directory.appendingPathComponent(name)
            #expect(try Data(contentsOf: url) == jpeg)
            let mode = try FileManager.default.attributesOfItem(
                atPath: url.path)[.posixPermissions] as? NSNumber
            #expect(mode?.int16Value == 0o600)
        }
        let jsonl = try String(
            contentsOf: directory.appendingPathComponent(ActivityLog.filename), encoding: .utf8)
        #expect(jsonl.contains("\"s\":\"shot-1.jpg\""))
        #expect(jsonl.contains("\"s\":\"shot-2.jpg\""))
    }

    @Test func activityRowsAreLostUnderTheSameUniformCapacityContract() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = ActivityLog()
        defer { projection.disable() }
        // 1_024 bytes fits the session-open envelope but not a screen-view row's JPEG.
        let evidence = FileSessionAudit(
            directory: directory,
            worker: SessionAuditWorker(
                limits: .init(maxEventCount: 32, maxRetainedBytes: 1_024),
                writer: SessionAuditFileWriter()),
            activity: projection)
        projection.enable(directory: directory, session: evidence.sessionID)

        evidence.record(
            .screenViewed(imageBase64JPEG: String(repeating: "A", count: 4_096)))
        evidence.record(.tip(lines: ["admitted after the oversize row"]))
        #expect(await evidence.close() == .partial)

        let jsonl = try String(
            contentsOf: directory.appendingPathComponent(ActivityLog.filename), encoding: .utf8)
        #expect(!jsonl.contains("looking at your screen"))
        #expect(jsonl.contains("admitted after the oversize row"))
        let health = try Data(
            contentsOf: directory.appendingPathComponent(FileSessionAudit.healthFilename))
        let marker = try #require(JSONSerialization.jsonObject(with: health) as? [String: Any])
        #expect(marker["state"] as? String == "partial")
        #expect(marker["oversize_record"] as? Int == 1)
    }

    @Test func lostEvidenceMarksTheLiveWindowIncompleteExactlyOnce() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = ActivityLog()
        defer { projection.disable() }
        let evidence = FileSessionAudit(
            directory: directory,
            worker: SessionAuditWorker(
                limits: .init(maxEventCount: 32, maxRetainedBytes: 1_024),
                writer: SessionAuditFileWriter()),
            activity: projection)
        projection.enable(directory: directory, session: evidence.sessionID)
        let pushedLock = NSLock()
        var pushed: [String] = []
        let snapshot = projection.attach { js in pushedLock.withLock { pushed.append(js) } }
        #expect(snapshot.evidenceIsComplete)
        evidence.record(.screenViewed(imageBase64JPEG: String(repeating: "A", count: 4_096)))
        evidence.record(.tip(lines: ["first row after the loss"]))
        evidence.record(.tip(lines: ["second row after the loss"]))
        #expect(await evidence.close() == .partial)

        let scripts = pushedLock.withLock { pushed }
        let notices = scripts.filter { $0.contains("setEvidence(") }
        #expect(notices.count == 1)
        #expect(notices[0] == ActivityLog.evidenceScript(isComplete: false))
        #expect(!projection.attach { _ in }.evidenceIsComplete)
    }

    @Test func completeEvidenceNeverAnnouncesANotice() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (projection, evidence) = ActivityLog.recordingSession(in: directory)
        defer { projection.disable() }
        let pushedLock = NSLock()
        var pushed: [String] = []
        _ = projection.attach { js in pushedLock.withLock { pushed.append(js) } }

        evidence.record(.tip(lines: ["a clean session"]))
        #expect(await evidence.close() == .complete)

        #expect(pushedLock.withLock { pushed }.allSatisfy { !$0.contains("setEvidence(") })
        #expect(projection.attach { _ in }.evidenceIsComplete)
    }

    @Test func aLossAtSealStillReachesTheWindow() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (projection, evidence) = ActivityLog.recordingSession(in: directory)
        defer { projection.disable() }
        _ = projection.attach { _ in }

        evidence.record(.tip(lines: ["the last row of a doomed session"]))
        evidence.abandon()
        #expect(await evidence.close() == .partial)

        #expect(!projection.attach { _ in }.evidenceIsComplete)
    }

    /// Parks only the first open: both sessions share this worker, so parking both would deadlock.
    /// @unchecked: `parked` is guarded by `lock`, and the semaphores are thread-safe.
    private final class ParkedOpenWriter: SessionAuditWriting, @unchecked Sendable {
        let openEntered = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var parked = false
        private let backing = SessionAuditFileWriter()

        func openSession(at directory: URL, initialHealth: Data) throws {
            let shouldPark = lock.withLock { () -> Bool in
                guard !parked else { return false }
                parked = true
                return true
            }
            if shouldPark {
                openEntered.signal()
                release.wait()
            }
            try backing.openSession(at: directory, initialHealth: initialHealth)
        }

        func append(_ data: Data, filename: String, in directory: URL) throws {
            try backing.append(data, filename: filename, in: directory)
        }

        func write(_ data: Data, filename: String, in directory: URL) throws {
            try backing.write(data, filename: filename, in: directory)
        }

        func replaceHealth(_ data: Data, in directory: URL) throws {
            try backing.replaceHealth(data, in: directory)
        }

        func emitToConsole(_ message: String) {}

        func releaseOpen() { release.signal() }
    }

    @Test func aLateRowFromTheStoppedSessionCannotKillTheNextSessionsWindow() async throws {
        let first = ActivityLogTests.tmp()
        let second = ActivityLogTests.tmp()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let writer = ParkedOpenWriter()
        let worker = SessionAuditWorker(limits: .production, writer: writer)
        let projection = ActivityLog()
        defer { projection.disable() }

        let sessionA = FileSessionAudit(directory: first, worker: worker, activity: projection)
        projection.enable(directory: first, session: sessionA.sessionID)
        wait(for: writer.openEntered)
        // The parked worker keeps A's terminal row queued while the projection rotates to B.
        sessionA.record(.sessionEnded(reason: .stoppedByUser))

        let sessionB = FileSessionAudit(directory: second, worker: worker, activity: projection)
        projection.enable(directory: second, session: sessionB.sessionID)

        writer.releaseOpen()
        #expect(await sessionA.close() == .partial)

        sessionB.record(.tip(lines: ["the replacement session is alive"]))
        #expect(await sessionB.close() == .complete)

        let rowsB = try String(
            contentsOf: second.appendingPathComponent(ActivityLog.filename), encoding: .utf8)
        #expect(rowsB.contains("the replacement session is alive"))
        #expect(!rowsB.contains("session ended by user"))
        let rowsA = try String(
            contentsOf: first.appendingPathComponent(ActivityLog.filename), encoding: .utf8)
        #expect(!rowsA.contains("session ended by user"))
    }

    @Test func aPartialCloseFromTheStoppedSessionCannotMarkTheNextSessionIncomplete() async throws {
        let first = ActivityLogTests.tmp()
        let second = ActivityLogTests.tmp()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let worker = SessionAuditWorker(
            limits: .init(maxEventCount: 32, maxRetainedBytes: 1_024),
            writer: SessionAuditFileWriter())
        let projection = ActivityLog()
        defer { projection.disable() }

        let sessionA = FileSessionAudit(directory: first, worker: worker, activity: projection)
        projection.enable(directory: first, session: sessionA.sessionID)
        sessionA.record(.screenViewed(imageBase64JPEG: String(repeating: "A", count: 4_096)))

        // B starts before A closes, as an immediate restart does.
        let sessionB = FileSessionAudit(directory: second, worker: worker, activity: projection)
        projection.enable(directory: second, session: sessionB.sessionID)
        #expect(await sessionA.close() == .partial)

        sessionB.record(.tip(lines: ["healthy replacement session"]))
        #expect(await sessionB.close() == .complete)
        #expect(projection.attach { _ in }.evidenceIsComplete)
    }

    private func wait(for semaphore: DispatchSemaphore) {
        #expect(semaphore.wait(timeout: .now() + 10) == .success)
    }

    @Test func theSessionEndMarkerStaysFinalOnTheSharedWorker() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (projection, evidence) = ActivityLog.recordingSession(in: directory)
        defer { projection.disable() }

        evidence.record(.tip(lines: ["before stop"]))
        evidence.record(.sessionEnded(reason: .stoppedByUser))
        evidence.record(.stayedSilent)
        #expect(await evidence.close() == .complete)

        let jsonl = try String(
            contentsOf: directory.appendingPathComponent(ActivityLog.filename), encoding: .utf8)
        #expect(jsonl.contains("before stop"))
        #expect(jsonl.contains("session ended by user"))
        #expect(!jsonl.contains("stayed silent"))
    }
}
