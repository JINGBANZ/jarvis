import Foundation
import Testing
@testable import JarvisCore

/// Phase 2, producer edge: an Activity occurrence is one `SessionEvent` on the shared transport,
/// and the human window is a projection of that event rather than a second call the producer makes.
@Suite struct ActivityProjectionTests {
    /// Terminal projection that records what the worker handed it, in delivery order.
    private final class RecordingProjection: ActivityEventRecording, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(kind: ActivityEvent.Kind, message: String, date: Date)] = []

        func record(_ event: ActivityEvent, at date: Date) {
            let rendered = event.rendered
            lock.withLock {
                storage.append((rendered.kind, rendered.message, date))
            }
        }

        var kinds: [ActivityEvent.Kind] { lock.withLock { storage.map(\.kind) } }
        var messages: [String] { lock.withLock { storage.map(\.message) } }
        var dates: [Date] { lock.withLock { storage.map(\.date) } }
    }

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
        let projection = RecordingProjection()
        let evidence = FileSessionAudit(
            directory: directory,
            worker: SessionAuditWorker(limits: .production, writer: SessionAuditFileWriter()),
            activity: projection)

        let heardAt = Date(timeIntervalSince1970: 1_755_000_042)
        evidence.record(.heard(speaker: .them, text: "what's the tradeoff?"), at: heardAt)
        evidence.record(.tip(lines: ["name the tradeoff"]))
        #expect(await evidence.close() == .complete)

        #expect(projection.kinds == [.heard, .tip])
        #expect(projection.messages[0] == "🗣 heard (them): \"what's the tradeoff?\"")
        #expect(projection.messages[1] == "💬 name the tradeoff")
        // Speech keeps its own speech-time so Activity and the model share one chronology.
        #expect(projection.dates[0] == heardAt)
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
        let activityLog = ActivityLog()
        defer { activityLog.disable() }
        activityLog.enable(directory: directory)
        let evidence = FileSessionAudit(
            directory: directory,
            worker: SessionAuditWorker(limits: .production, writer: SessionAuditFileWriter()),
            activity: activityLog)

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
}
