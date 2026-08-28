import Foundation
import Testing
@testable import JarvisCore

@Suite struct SessionEventTests {
    @Test func envelopeDerivesKindTimingAndAttributionFromTypedDetail() {
        let sessionID = UUID()
        let occurred = Date(timeIntervalSince1970: 1_755_000_000)

        let traffic = SessionEvent(
            sessionID: sessionID,
            detail: .brainTraffic(BrainTrafficAuditEvent(
                tag: "coach",
                request: Data(#"{"model":"gpt-5.5"}"#.utf8),
                response: nil,
                status: nil,
                latencyMs: 12,
                error: nil,
                phases: nil,
                kind: .providerCall,
                requestContext: CoachingRequestAttribution.context(
                    attemptID: 7,
                    wake: .trigger,
                    reason: .turnEnd,
                    phase: .initial,
                    sequence: 1),
                date: occurred)))
        #expect(traffic.version == SessionEvent.currentVersion)
        #expect(traffic.kind == .brainTraffic)
        #expect(traffic.kind.rawValue == "brain_traffic")
        #expect(traffic.sessionID == sessionID)
        #expect(traffic.occurredAt == occurred)
        #expect(traffic.attemptID == 7)
        #expect(traffic.activityPresentation == nil)

        let unattributed = SessionEvent(
            sessionID: sessionID,
            detail: .brainTraffic(BrainTrafficAuditEvent(
                tag: "summarizer",
                request: Data(),
                response: nil,
                status: nil,
                latencyMs: 8,
                error: nil,
                phases: nil,
                kind: .providerCall,
                requestContext: nil,
                date: occurred)))
        #expect(unattributed.attemptID == nil)

        let finished = SessionEvent(
            sessionID: sessionID,
            detail: .coachingAttempt(.finished(.init(
                attemptID: 3,
                terminal: .staySilent,
                outcome: .silentByModel,
                date: occurred))))
        #expect(finished.kind == .coachingAttempt)
        #expect(finished.kind.rawValue == "coaching_attempt")
        #expect(finished.occurredAt == occurred)
        #expect(finished.attemptID == 3)
    }

    /// The expand-step pin: admitting through the typed producer views and admitting the same
    /// occurrences as envelopes — even with an Activity presentation attached — must leave the
    /// persisted session folder byte-for-byte identical.
    @Test func typedViewsAndEnvelopeAdmissionPersistByteIdenticalRecords() async throws {
        let viewDirectory = ActivityLogTests.tmp()
        let envelopeDirectory = ActivityLogTests.tmp()
        defer {
            try? FileManager.default.removeItem(at: viewDirectory)
            try? FileManager.default.removeItem(at: envelopeDirectory)
        }
        let occurred = Date(timeIntervalSince1970: 1_755_000_000)
        let trafficEvent = BrainTrafficAuditEvent(
            tag: "coach",
            request: Data(#"{"model":"gpt-5.5"}"#.utf8),
            response: Data(#"{"status":"completed"}"#.utf8),
            status: 200,
            latencyMs: 12,
            error: nil,
            phases: nil,
            kind: .providerCall,
            requestContext: nil,
            date: occurred)
        let transcript = [TranscriptLine(speaker: .them, text: "Explain the tradeoff", at: 1)]
        let startedEvent = CoachingAttemptAuditEvent.started(.init(
            attemptID: 3,
            wake: .trigger,
            reason: .turnEnd,
            target: BrainTarget(provider: .openAI, modelID: "gpt-5.5"),
            transcriptStartIndex: 8,
            transcriptLines: transcript,
            classifications: [.substantive],
            brainFacingTranscriptIndices: [8],
            date: occurred))
        let finishedEvent = CoachingAttemptAuditEvent.finished(.init(
            attemptID: 3,
            terminal: .speak,
            outcome: .spoke,
            date: occurred))

        let viewAudit = await FileSessionAudit.readyForTesting(directory: viewDirectory)
        viewAudit.record(trafficEvent)
        viewAudit.record(startedEvent)
        viewAudit.record(finishedEvent)
        #expect(await viewAudit.closeForTesting() == .complete)

        let envelopeAudit = await FileSessionAudit.readyForTesting(directory: envelopeDirectory)
        envelopeAudit.record(
            .brainTraffic(trafficEvent),
            presentingInActivity: .tip(lines: ["same tip"]))
        envelopeAudit.record(.coachingAttempt(startedEvent))
        envelopeAudit.record(.coachingAttempt(finishedEvent))
        #expect(await envelopeAudit.closeForTesting() == .complete)

        for filename in [
            FileSessionAudit.brainTrafficFilename,
            FileSessionAudit.coachingAttemptsFilename,
            FileSessionAudit.healthFilename,
        ] {
            let viewBytes = try Data(
                contentsOf: viewDirectory.appendingPathComponent(filename))
            let envelopeBytes = try Data(
                contentsOf: envelopeDirectory.appendingPathComponent(filename))
            #expect(viewBytes == envelopeBytes, "\(filename) diverged between admission paths")
            #expect(!viewBytes.isEmpty, "\(filename) comparison must not be vacuous")
        }
    }

    /// The retained-byte bound covers the whole envelope, not only its typed detail: a small
    /// occurrence dragging an oversize Activity presentation is dropped, and later admission
    /// continues independently.
    @Test func anOversizeActivityPresentationCountsAgainstTheByteBound() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audit = FileSessionAudit(
            directory: directory,
            worker: SessionAuditWorker(
                limits: .init(maxEventCount: 8, maxRetainedBytes: 1_024),
                writer: SessionAuditFileWriter()))
        await waitForHealthMarker(in: directory)

        audit.record(
            .brainTraffic(BrainTrafficAuditEvent(
                tag: "small-detail",
                request: Data(#"{"model":"gpt-5.5"}"#.utf8),
                response: nil,
                status: nil,
                latencyMs: 5,
                error: nil,
                phases: nil,
                kind: .providerCall,
                requestContext: nil,
                date: Date())),
            presentingInActivity: .screenViewed(
                imageBase64JPEG: String(repeating: "A", count: 4_096)))
        audit.record(
            tag: "after-presentation-drop",
            request: Data(#"{"model":"gpt-5.5"}"#.utf8),
            response: nil,
            status: nil,
            latencyMs: 5)

        #expect(await audit.close() == .partial)
        let text = try String(
            contentsOf: directory.appendingPathComponent(
                FileSessionAudit.brainTrafficFilename),
            encoding: .utf8)
        let tags = text.split(separator: "\n")
            .compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
            .compactMap { $0["tag"] as? String }
        #expect(tags == ["after-presentation-drop"])
        let health = try Data(
            contentsOf: directory.appendingPathComponent(FileSessionAudit.healthFilename))
        let marker = try #require(
            JSONSerialization.jsonObject(with: health) as? [String: Any])
        #expect(marker["state"] as? String == "partial")
        #expect(marker["oversize_record"] as? Int == 1)
    }

    private func waitForHealthMarker(in directory: URL) async {
        let marker = directory.appendingPathComponent(FileSessionAudit.healthFilename)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: marker.path),
              ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }
}
