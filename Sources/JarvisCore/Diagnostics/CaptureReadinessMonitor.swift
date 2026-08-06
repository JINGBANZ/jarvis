import Foundation

/// Foundation-only authority for when captured audio *frames* — not just ready provider sessions —
/// make a coaching session fully live. Both required capture streams must deliver at least one frame
/// before listening is reported, and a stream that never delivers (an initial first-frame timeout) or
/// stops delivering after readiness (a sustained stall) is converted into the appropriate typed
/// lifecycle consequence: the microphone is terminal, the system stream degrades to microphone-only.
///
/// Readiness is based purely on callback/frame arrival, never signal amplitude — valid digital silence
/// still counts as healthy capture, so the caller feeds `.firstFrame` for any delivered chunk regardless
/// of its samples. It consumes `AudioContinuityWitness` stall evidence (surfaced as `Signal.stalled` /
/// `.resumed`) rather than running a second competing counter, and the caller supplies every timestamp
/// so the policy is deterministic and unit-testable with no timer of its own.
public final class CaptureReadinessMonitor {
    /// The two independent capture paths fed by the one-clock aggregate device.
    public enum Stream: String, Sendable, Equatable, CaseIterable {
        case microphone
        case system
    }

    /// A content-free capture observation for one stream, derived from the continuity witness.
    public enum Signal: Sendable, Equatable {
        /// The first captured frame for this stream reached delivery (any sample count, silence included).
        case firstFrame
        /// The witness reported a capture stall (no frames for its stall threshold).
        case stalled
        /// Frames resumed after a prior `stalled`.
        case resumed
    }

    /// Why a stream's capture path was ruled unhealthy — kept for the debug log; Activity copy is fixed.
    public enum FailureCause: String, Sendable, Equatable {
        case firstFrameTimeout
        case sustainedStall
    }

    /// A lifecycle consequence the caller must apply. Both are silent, ghost-safe outcomes.
    public enum Effect: Sendable, Equatable {
        /// The microphone capture path failed; coaching must stop. Terminal.
        case microphoneCaptureFailed(FailureCause)
        /// The system capture path can't stay healthy; degrade to microphone-only. Non-terminal.
        case degradeToMicrophoneOnly(FailureCause)
    }

    public struct Configuration: Sendable, Equatable {
        /// How long a required stream may go without its first frame before its path is ruled failed.
        public let firstFrameTimeout: TimeInterval
        /// How long an established stream may stay stalled before its path is ruled failed. Kept well
        /// above the witness stall threshold so a normal debounced capture route rebuild rides through.
        public let sustainedStallTimeout: TimeInterval

        public init(firstFrameTimeout: TimeInterval = 6, sustainedStallTimeout: TimeInterval = 12) {
            precondition(firstFrameTimeout > 0 && sustainedStallTimeout > 0)
            self.firstFrameTimeout = firstFrameTimeout
            self.sustainedStallTimeout = sustainedStallTimeout
        }
    }

    private struct StreamState {
        var required: Bool
        var firstFrame = false
        var stalledSince: TimeInterval?
        /// A consequence was already applied, or the stream was declared unavailable. Sticky: no later
        /// or duplicate observation can re-arm it or resurrect readiness.
        var resolved = false
    }

    private let configuration: Configuration
    private let startedAt: TimeInterval
    private var streams: [Stream: StreamState]
    /// Set once the microphone fails: the session is ending, so every subsequent observation is inert.
    private var stopped = false

    /// `startedAt` is the session-relative origin the first-frame deadline is measured from; all later
    /// timestamps must share that monotonic clock.
    public init(configuration: Configuration = .init(),
                requiresSystemAudio: Bool = true,
                startedAt: TimeInterval) {
        self.configuration = configuration
        self.startedAt = startedAt
        streams = [
            .microphone: StreamState(required: true),
            .system: StreamState(required: requiresSystemAudio),
        ]
    }

    /// Whether this stream has delivered at least one frame (its provider readiness is tracked
    /// separately by the caller; full listening requires both).
    public func hasFirstFrame(_ stream: Stream) -> Bool {
        streams[stream]?.firstFrame == true
    }

    /// Whether the system stream has been ruled unavailable (a capture consequence or an out-of-band
    /// degrade), so the caller shows microphone-only rather than waiting on system audio.
    public var isSystemUnavailable: Bool {
        streams[.system]?.resolved == true
    }

    /// Record one capture observation for a stream and advance time-based policy. Late or duplicate
    /// signals after a stream is resolved (or after the microphone failed) are inert.
    @discardableResult
    public func note(_ signal: Signal, for stream: Stream, at time: TimeInterval) -> [Effect] {
        guard !stopped, var state = streams[stream], !state.resolved else { return [] }
        switch signal {
        case .firstFrame:
            state.firstFrame = true
            state.stalledSince = nil
        case .resumed:
            state.stalledSince = nil
        case .stalled:
            if state.stalledSince == nil { state.stalledSince = time }
        }
        streams[stream] = state
        return poll(at: time)
    }

    /// Declare the system stream unavailable for a reason outside capture (e.g. its transcription
    /// endpoint gave up). Stops any pending capture timeout from also firing for it.
    public func systemBecameUnavailable() {
        guard var state = streams[.system], !state.resolved else { return }
        state.resolved = true
        state.required = false
        streams[.system] = state
    }

    /// Advance the initial first-frame deadline and the post-ready sustained-stall deadline. Returns at
    /// most one effect; a microphone failure supersedes any system degradation on the same tick.
    @discardableResult
    public func poll(at time: TimeInterval) -> [Effect] {
        guard !stopped else { return [] }
        if let cause = failureCause(for: .microphone, at: time) {
            stopped = true
            resolve(.microphone)
            return [.microphoneCaptureFailed(cause)]
        }
        if let cause = failureCause(for: .system, at: time) {
            resolve(.system)
            return [.degradeToMicrophoneOnly(cause)]
        }
        return []
    }

    private func failureCause(for stream: Stream, at time: TimeInterval) -> FailureCause? {
        guard let state = streams[stream], state.required, !state.resolved else { return nil }
        if !state.firstFrame {
            return time - startedAt >= configuration.firstFrameTimeout ? .firstFrameTimeout : nil
        }
        if let stalledSince = state.stalledSince,
           time - stalledSince >= configuration.sustainedStallTimeout {
            return .sustainedStall
        }
        return nil
    }

    private func resolve(_ stream: Stream) {
        guard var state = streams[stream] else { return }
        state.resolved = true
        streams[stream] = state
    }
}
