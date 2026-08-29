import Foundation

/// Content-free audio-frame progress for one capture stream.
///
/// The heartbeat is frame *arrival* and nothing else. It is not a timer ping, not a network liveness
/// probe, not an audio recording, and not a second counter beside `AudioContinuityWitness` — it is
/// that witness's own frame evidence, promoted at the moments the evidence changes meaning. Positive
/// sample progress is health regardless of amplitude, so valid digital silence still counts as
/// healthy capture; a zero-length callback does not. No amplitude and no PCM cross this boundary.
///
/// One observation, two one-way consumers (wiki/lean-coaching-core.md, "Capture Heartbeat"):
///
/// 1. **Critical, in-memory.** `CaptureReadinessMonitor` folds it into capture health policy, where
///    it can keep readiness pending, degrade system audio to microphone-only, or stop an unusable
///    microphone session.
/// 2. **Optional evidence.** A projection of the very same value enters `SessionEvidence` so an
///    agent can reconstruct what happened later.
///
/// Losing the evidence copy may make a session's record partial. It can never change a readiness,
/// degradation, or stop decision: the critical branch reads this value directly and never reads the
/// evidence queue or a persisted file.
public enum CaptureHeartbeat: Sendable, Equatable {
    /// A callback delivered this many samples. Positive progress establishes or restores frame
    /// health; zero samples do not.
    case frames(sampleCount: Int)
    /// The continuity witness reported a capture stall — no frames for its stall threshold.
    case stalled

    /// The optional evidence copy's text. Content-free by construction: a sample count or the word
    /// "stalled", never audio, amplitude, or transcript.
    public var evidenceDescription: String {
        switch self {
        case .frames(let sampleCount): "frames=\(sampleCount)"
        case .stalled: "stalled"
        }
    }
}

/// Decides when raw frame arrival is worth promoting to a heartbeat.
///
/// Frames arrive continuously; the heartbeat is the small set of moments that carry new information
/// — the first frame of a stream, and the first frame after a stall. Keeping that latch here rather
/// than at the capture edge makes it Foundation-only policy the capture-health tests can drive
/// directly, and gives both capture adapters one implementation instead of two.
///
/// `@unchecked Sendable`: the two latches are guarded by `lock`, and frames arrive on realtime audio
/// callbacks.
public final class CaptureHeartbeatGate: @unchecked Sendable {
    private let lock = NSLock()
    private var sawFirstFrame = false
    private var stallOutstanding = false

    public init() {}

    /// Forget both latches for a new capture session.
    public func reset() {
        lock.withLock {
            sawFirstFrame = false
            stallOutstanding = false
        }
    }

    /// One capture callback arrived. Returns the heartbeat to promote, or nil when this callback
    /// tells the health policy nothing it does not already know.
    public func frames(sampleCount: Int) -> CaptureHeartbeat? {
        precondition(sampleCount >= 0)
        guard sampleCount > 0 else { return nil }
        return lock.withLock { () -> CaptureHeartbeat? in
            let promote = !sawFirstFrame || stallOutstanding
            sawFirstFrame = true
            stallOutstanding = false
            return promote ? .frames(sampleCount: sampleCount) : nil
        }
    }

    /// The witness reported a capture stall. Returns the heartbeat to promote, or nil when a stall
    /// is already outstanding — a repeated warning about the same gap is not new information.
    public func stalled() -> CaptureHeartbeat? {
        lock.withLock { () -> CaptureHeartbeat? in
            guard !stallOutstanding else { return nil }
            stallOutstanding = true
            return .stalled
        }
    }
}
