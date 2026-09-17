import Foundation

// Design: wiki/lean-coaching-core.md#capture-heartbeat
/// Content-free: no amplitude or PCM crosses this boundary. Positive sample progress is health even
/// in digital silence; a zero-length callback is not.
public enum CaptureHeartbeat: Sendable, Equatable {
    case frames(sampleCount: Int)
    case stalled

    /// Never audio, amplitude, or transcript.
    public var evidenceDescription: String {
        switch self {
        case .frames(let sampleCount): "frames=\(sampleCount)"
        case .stalled: "stalled"
        }
    }
}

/// `@unchecked Sendable`: `lock` guards both latches; frames arrive on realtime audio callbacks.
public final class CaptureHeartbeatGate: @unchecked Sendable {
    private let lock = NSLock()
    private var sawFirstFrame = false
    private var stallOutstanding = false

    public init() {}

    public func reset() {
        lock.withLock {
            sawFirstFrame = false
            stallOutstanding = false
        }
    }

    /// Nil when this callback tells the health policy nothing new.
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

    /// Nil while a stall is already outstanding.
    public func stalled() -> CaptureHeartbeat? {
        lock.withLock { () -> CaptureHeartbeat? in
            guard !stallOutstanding else { return nil }
            stallOutstanding = true
            return .stalled
        }
    }
}
