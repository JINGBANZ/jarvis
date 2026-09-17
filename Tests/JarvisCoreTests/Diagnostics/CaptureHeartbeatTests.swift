import Foundation
import Testing
@testable import JarvisCore

/// Serialized because the evidence-pressure cases install the process-global `JarvisLog`
/// attachment.
@Suite(.serialized) struct CaptureHeartbeatTests {
    private struct CriticalOutcome: Equatable {
        var readiness: [CaptureReadinessMonitor.Readiness] = []
        var effects: [CaptureReadinessMonitor.Effect] = []
        var systemUnavailable: [Bool] = []
    }

    private func runCriticalBranch(emittingEvidence: Bool = false) -> CriticalOutcome {
        let monitor = CaptureReadinessMonitor(
            configuration: .init(firstFrameTimeout: 6, sustainedStallTimeout: 12),
            startedAt: 0)
        let gates: [CaptureReadinessMonitor.Stream: CaptureHeartbeatGate] = [
            .microphone: CaptureHeartbeatGate(), .system: CaptureHeartbeatGate(),
        ]
        var outcome = CriticalOutcome()

        func record(_ body: () -> [CaptureReadinessMonitor.Effect]) {
            outcome.effects.append(contentsOf: body())
            outcome.readiness.append(monitor.readiness)
            outcome.systemUnavailable.append(monitor.isSystemUnavailable)
        }

        /// Mirrors `RealtimeContinuityReporter.emit`: critical branch first, evidence copy second.
        func beat(
            _ promoted: CaptureHeartbeat?,
            for stream: CaptureReadinessMonitor.Stream,
            at time: TimeInterval
        ) {
            guard let promoted else {
                record { [] }   // still samples readiness when nothing is promoted
                return
            }
            record { monitor.note(promoted, for: stream, at: time) }
            if emittingEvidence {
                jlog("Jarvis capture heartbeat [\(stream.rawValue), OpenAI Realtime]: "
                     + promoted.evidenceDescription)
            }
        }

        record { monitor.setProviderReady(true, for: .microphone); return [] }
        record { monitor.setProviderReady(true, for: .system); return [] }
        beat(gates[.microphone]!.frames(sampleCount: 0), for: .microphone, at: 1)
        beat(gates[.microphone]!.frames(sampleCount: 512), for: .microphone, at: 1)
        beat(gates[.system]!.frames(sampleCount: 512), for: .system, at: 1)
        beat(gates[.system]!.frames(sampleCount: 512), for: .system, at: 1)
        beat(gates[.system]!.stalled(), for: .system, at: 2)
        beat(gates[.system]!.stalled(), for: .system, at: 3)
        record { monitor.poll(at: 13) }      // system passes its sustained-stall deadline
        beat(gates[.microphone]!.stalled(), for: .microphone, at: 20)
        record { monitor.poll(at: 33) }      // microphone passes its own
        record { monitor.poll(at: 40) }      // stopped: every later observation is inert
        return outcome
    }

    @Test func theGatePromotesOnlyTheFirstFrameAndTheFirstFrameAfterAStall() {
        let gate = CaptureHeartbeatGate()
        #expect(gate.frames(sampleCount: 0) == nil)
        #expect(gate.frames(sampleCount: 512) == .frames(sampleCount: 512))
        #expect(gate.frames(sampleCount: 512) == nil)
        #expect(gate.stalled() == .stalled)
        #expect(gate.stalled() == nil)
        #expect(gate.frames(sampleCount: 256) == .frames(sampleCount: 256))
        #expect(gate.frames(sampleCount: 256) == nil)

        gate.reset()
        #expect(gate.frames(sampleCount: 128) == .frames(sampleCount: 128))
    }

    @Test func theEvidenceCopyIsContentFree() {
        #expect(CaptureHeartbeat.frames(sampleCount: 480).evidenceDescription == "frames=480")
        #expect(CaptureHeartbeat.stalled.evidenceDescription == "stalled")
    }

    @Test func evidencePressureCannotChangeReadinessDegradationOrStop() async throws {
        let baseline = runCriticalBranch()
        #expect(baseline.readiness.contains(.ready))
        #expect(baseline.effects == [
            .degradeToMicrophoneOnly(.sustainedStall),
            .microphoneCaptureFailed(.sustainedStall),
        ])
        #expect(baseline.readiness.last == .stopped)

        for variant in try evidenceVariants() {
            try await JarvisLogAttachmentLock.withExclusiveAttachment {
                defer {
                    JarvisLog.detach()
                    try? FileManager.default.removeItem(at: variant.directory)
                }
                JarvisLog.attach(to: variant.evidence)
                let outcome = runCriticalBranch(emittingEvidence: true)
                variant.release?()
                #expect(outcome == baseline, "evidence variant \(variant.name) changed coaching health")
                #expect(await variant.evidence.close() == variant.expectedClose)
            }
        }
    }

    private struct EvidenceVariant {
        let name: String
        let directory: URL
        let evidence: FileSessionAudit
        let expectedClose: SessionAuditCloseResult
        let release: (() -> Void)?
    }

    private func evidenceVariants() throws -> [EvidenceVariant] {
        let healthyDirectory = ActivityLogTests.tmp()
        let fullDirectory = ActivityLogTests.tmp()
        let failingDirectory = ActivityLogTests.tmp()

        let blockingWriter = BlockingWriter()
        let full = FileSessionAudit(
            directory: fullDirectory,
            worker: SessionAuditWorker(
                limits: .init(maxEventCount: 1, maxRetainedBytes: 4_096),
                writer: blockingWriter))
        #expect(blockingWriter.openEntered.wait(timeout: .now() + 10) == .success)

        let failingWriter = FailingAppendWriter()
        return [
            EvidenceVariant(
                name: "healthy",
                directory: healthyDirectory,
                evidence: FileSessionAudit(
                    directory: healthyDirectory,
                    worker: SessionAuditWorker(
                        limits: .production, writer: SessionAuditFileWriter())),
                expectedClose: .complete,
                release: nil),
            EvidenceVariant(
                name: "blocked and full",
                directory: fullDirectory,
                evidence: full,
                expectedClose: .partial,
                release: { blockingWriter.releaseOpen() }),
            EvidenceVariant(
                name: "failing writes",
                directory: failingDirectory,
                evidence: FileSessionAudit(
                    directory: failingDirectory,
                    worker: SessionAuditWorker(limits: .production, writer: failingWriter)),
                expectedClose: .partial,
                release: nil),
        ]
    }

    /// @unchecked: its only state is two thread-safe semaphores.
    private final class BlockingWriter: SessionAuditWriting, @unchecked Sendable {
        let openEntered = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private let backing = SessionAuditFileWriter()

        func openSession(at directory: URL, initialHealth: Data) throws {
            openEntered.signal()
            release.wait()
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

    private struct FailingAppendWriter: SessionAuditWriting {
        enum Failure: Error { case injected }
        private let backing = SessionAuditFileWriter()

        func openSession(at directory: URL, initialHealth: Data) throws {
            try backing.openSession(at: directory, initialHealth: initialHealth)
        }

        func append(_ data: Data, filename: String, in directory: URL) throws {
            throw Failure.injected
        }

        func write(_ data: Data, filename: String, in directory: URL) throws {
            throw Failure.injected
        }

        func replaceHealth(_ data: Data, in directory: URL) throws {
            try backing.replaceHealth(data, in: directory)
        }

        func emitToConsole(_ message: String) {}
    }
}
