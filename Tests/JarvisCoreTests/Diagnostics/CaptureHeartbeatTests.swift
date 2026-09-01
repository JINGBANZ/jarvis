import Foundation
import Testing
@testable import JarvisCore

/// Capture heartbeat: one content-free observation, two one-way consumers.
///
/// The rename is not the point. The point is the asymmetry — losing, blocking, or failing the
/// optional evidence copy may make a session's record partial, and can never change a readiness,
/// microphone-only degradation, or stop decision.
///
/// Serialized because the evidence-pressure cases install a process-global `JarvisLog` attachment —
/// `JarvisLogAttachmentLock` additionally guards it against the other suites that do the same, since
/// `.serialized` only covers cases within this one suite.
@Suite(.serialized) struct CaptureHeartbeatTests {
    /// The complete observable output of the critical branch for one heartbeat script: what the app
    /// would render, and every lifecycle consequence it would apply, in order.
    private struct CriticalOutcome: Equatable {
        var readiness: [CaptureReadinessMonitor.Readiness] = []
        var effects: [CaptureReadinessMonitor.Effect] = []
        var systemUnavailable: [Bool] = []
    }

    /// One fixed script that walks the whole capture-health surface: both streams reach first frame
    /// and go ready, the system stream stalls long enough to degrade to microphone-only, then the
    /// microphone stalls long enough to stop the session.
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

        /// The capture edge's fan-out, exactly as `RealtimeContinuityReporter.emit` performs it:
        /// the critical branch runs first and unconditionally, the evidence copy second.
        func beat(
            _ promoted: CaptureHeartbeat?,
            for stream: CaptureReadinessMonitor.Stream,
            at time: TimeInterval
        ) {
            guard let promoted else {
                record { [] }   // nothing promoted; policy still observes the passage of time
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
        // A zero-length callback is not health: the gate refuses to promote it at all.
        beat(gates[.microphone]!.frames(sampleCount: 0), for: .microphone, at: 1)
        beat(gates[.microphone]!.frames(sampleCount: 512), for: .microphone, at: 1)
        beat(gates[.system]!.frames(sampleCount: 512), for: .system, at: 1)
        // Steady flow promotes nothing, so it cannot re-arm anything either.
        beat(gates[.system]!.frames(sampleCount: 512), for: .system, at: 1)
        beat(gates[.system]!.stalled(), for: .system, at: 2)
        beat(gates[.system]!.stalled(), for: .system, at: 3)
        record { monitor.poll(at: 13) }      // system passes its sustained-stall deadline
        beat(gates[.microphone]!.stalled(), for: .microphone, at: 20)
        record { monitor.poll(at: 33) }      // microphone passes its own
        record { monitor.poll(at: 40) }      // stopped: every later observation is inert
        return outcome
    }

    /// The gate promotes only the moments that carry new information, and never a zero-length
    /// callback. It is the same frame evidence the witness already holds, not a second counter.
    @Test func theGatePromotesOnlyTheFirstFrameAndTheFirstFrameAfterAStall() {
        let gate = CaptureHeartbeatGate()
        #expect(gate.frames(sampleCount: 0) == nil)          // zero-length callback: not health
        #expect(gate.frames(sampleCount: 512) == .frames(sampleCount: 512))
        #expect(gate.frames(sampleCount: 512) == nil)        // steady flow says nothing new
        #expect(gate.stalled() == .stalled)
        #expect(gate.stalled() == nil)                       // the same gap, warned about twice
        #expect(gate.frames(sampleCount: 256) == .frames(sampleCount: 256))   // recovery
        #expect(gate.frames(sampleCount: 256) == nil)

        gate.reset()
        #expect(gate.frames(sampleCount: 128) == .frames(sampleCount: 128))
    }

    /// The heartbeat carries frame progress and nothing else — no amplitude, no PCM, no transcript.
    @Test func theEvidenceCopyIsContentFree() {
        #expect(CaptureHeartbeat.frames(sampleCount: 480).evidenceDescription == "frames=480")
        #expect(CaptureHeartbeat.stalled.evidenceDescription == "stalled")
    }

    /// The deliverable: capture health decisions are byte-identical whether the evidence copy has
    /// nowhere to go, is blocked behind a parked writer, overflows a one-slot mailbox, or fails
    /// every write.
    @Test func evidencePressureCannotChangeReadinessDegradationOrStop() async throws {
        let baseline = runCriticalBranch()
        // Pin the baseline so the invariant is not vacuous: the script really does reach ready,
        // degrade to microphone-only, and then stop.
        #expect(baseline.readiness.contains(.ready))
        #expect(baseline.effects == [
            .degradeToMicrophoneOnly(.sustainedStall),
            .microphoneCaptureFailed(.sustainedStall),
        ])
        #expect(baseline.readiness.last == .stopped)

        for variant in try evidenceVariants() {
            JarvisLogAttachmentLock.acquire()
            defer { JarvisLogAttachmentLock.release() }
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

    private struct EvidenceVariant {
        let name: String
        let directory: URL
        let evidence: FileSessionAudit
        let expectedClose: SessionAuditCloseResult
        let release: (() -> Void)?
    }

    /// Blocked, full, and failing evidence destinations, plus one healthy control.
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

    /// Parks the worker in its first open so admission overflows a one-slot mailbox.
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

    /// Every record write fails; the session's health record is the only trace.
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
