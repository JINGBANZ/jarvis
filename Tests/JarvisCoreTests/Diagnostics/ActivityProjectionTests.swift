import Foundation
import Testing
@testable import JarvisCore

/// Phase 2, producer edge: an Activity occurrence is one `SessionEvent` on the shared transport,
/// and the human window is a projection of that event rather than a second call the producer makes.
@Suite struct ActivityProjectionTests {
    /// The envelope derives everything about an Activity occurrence from its typed detail, so the
    /// human copy an event carries can never disagree with what the event says happened.
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

    /// The other detail categories carry no human copy at all: a provider timing, a transport
    /// error, or a raw diagnostic has nothing to say in the Activity window.
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

    /// The producer hands the occurrence to the session handle; the worker — not the producer —
    /// renders it into the human projection, preserving the occurrence's own time.
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
        // Speech keeps its own speech-time so Activity and the model share one chronology.
        #expect(first["o"] as? Double == heardAt.timeIntervalSince1970)
    }

    /// A session with no Activity destination still admits and persists everything else. Absent
    /// human copy is an evidence state, never a coaching one.
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

    /// The end-to-end shape the app composes: kernel → session handle → `ActivityLog`. The window's
    /// content for each kind is what it was when the driver called `ActivityLog` directly.
    @Test func kernelOccurrencesReachTheActivityWindowThroughTheSharedHandle() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (activityLog, evidence) = ActivityLog.recordingSession(in: directory)
        defer { activityLog.disable() }

        evidence.record(.manualHint(prompt: "unblock me"))
        evidence.record(.screenViewFailed)
        evidence.record(.tip(lines: ["say the number"]))
        #expect(await evidence.close() == .complete)

        let snapshot = activityLog.attach { _ in }   // sync barrier on the projection's own queue
        #expect(snapshot.total == 3)
        let jsonl = try String(
            contentsOf: directory.appendingPathComponent(ActivityLog.filename), encoding: .utf8)
        #expect(jsonl.contains("⌨️ hint shortcut — unblock me"))
        #expect(jsonl.contains("👁 couldn't view your screen"))
        #expect(jsonl.contains("💬 say the number"))
        #expect(jsonl.contains("\"k\":\"manualHint\""))
        #expect(jsonl.contains("\"k\":\"tip\""))
        // The human record stays free of transport, retry, and raw-error detail.
        #expect(!jsonl.contains("audit_version"))
    }

    /// The screenshot attachment is written by the worker, owner-only, inside the session directory
    /// — never `/tmp` — and always before the row that references it.
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

    /// Activity has no reserved capacity: a row that does not fit is lost like any other evidence,
    /// the session reads partial, and the next row is admitted on its own merits.
    @Test func activityRowsAreLostUnderTheSameUniformCapacityContract() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = ActivityLog()
        defer { projection.disable() }
        projection.enable(directory: directory)
        // The byte cap sits above the session-open envelope and below a screen-view row's JPEG.
        let evidence = FileSessionAudit(
            directory: directory,
            worker: SessionAuditWorker(
                limits: .init(maxEventCount: 32, maxRetainedBytes: 1_024),
                writer: SessionAuditFileWriter()),
            activity: projection)

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

    /// Live: the moment the shared worker records a loss, the window is told the record has holes.
    /// The signal is the existing monotonic health record, so it is announced once and never
    /// retracted.
    @Test func lostEvidenceMarksTheLiveWindowIncompleteExactlyOnce() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = ActivityLog()
        defer { projection.disable() }
        projection.enable(directory: directory)
        let pushedLock = NSLock()
        var pushed: [String] = []
        let snapshot = projection.attach { js in pushedLock.withLock { pushed.append(js) } }
        #expect(snapshot.evidenceIsComplete)

        let evidence = FileSessionAudit(
            directory: directory,
            worker: SessionAuditWorker(
                limits: .init(maxEventCount: 32, maxRetainedBytes: 1_024),
                writer: SessionAuditFileWriter()),
            activity: projection)
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

    /// A session that records everything it was given never claims to be incomplete.
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

    /// Sealing is the last honest moment: a loss recorded after the final row still reaches a window
    /// that is still showing the session.
    @Test func aLossAtSealStillReachesTheWindow() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (projection, evidence) = ActivityLog.recordingSession(in: directory)
        defer { projection.disable() }
        _ = projection.attach { _ in }

        evidence.record(.tip(lines: ["the last row of a doomed session"]))
        // Abandon is the Quit path: it seals immediately and forces a partial marker.
        evidence.abandon()
        #expect(await evidence.close() == .partial)

        #expect(!projection.attach { _ in }.evidenceIsComplete)
    }

    /// The session-end marker is still final for the session, now that it is admitted on the shared
    /// worker rather than on the projection's own queue.
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
