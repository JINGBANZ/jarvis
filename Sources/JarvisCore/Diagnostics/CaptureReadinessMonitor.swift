import Foundation

/// Foundation-only authority that combines provider readiness with captured audio *frame* health.
/// Both required streams must have a ready provider and at least one positive-sample callback before
/// full listening is reported. A stream that never delivers samples (an initial first-frame timeout)
/// or stops delivering after frame flow begins (a sustained stall) is converted into the appropriate
/// typed lifecycle consequence: the microphone is terminal, while the system stream degrades to
/// microphone-only.
///
/// Readiness is based purely on callback/frame arrival, never signal amplitude — valid digital silence
/// still counts as healthy capture. Its one input is the `CaptureHeartbeat` — content-free frame
/// progress derived from `AudioContinuityWitness`, not a second competing counter — and the caller
/// supplies every timestamp so the policy is deterministic and unit-testable with no timer of its
/// own.
public final class CaptureReadinessMonitor {
    /// The two independent capture paths fed by the one-clock aggregate device.
    public enum Stream: String, Sendable, Equatable, CaseIterable {
        case microphone
        case system
    }

    /// Capture-aware readiness for the app to render. Connection attempt details remain app-owned,
    /// but the rule that provider readiness and frame health are both required stays in Core.
    public enum Readiness: Sendable, Equatable {
        case waitingForMicrophone
        case waitingForSystem
        case ready
        case microphoneOnly
        case stopped
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
        /// How long an established stream may stay stalled while no capture recovery is active before
        /// its path is ruled failed.
        public let sustainedStallTimeout: TimeInterval

        public init(firstFrameTimeout: TimeInterval = 6, sustainedStallTimeout: TimeInterval = 12) {
            precondition(firstFrameTimeout > 0 && sustainedStallTimeout > 0)
            self.firstFrameTimeout = firstFrameTimeout
            self.sustainedStallTimeout = sustainedStallTimeout
        }
    }

    private struct StreamState {
        var required: Bool
        var firstFrameWaitingSince: TimeInterval
        var providerReady = false
        var firstFrame = false
        var stalledSince: TimeInterval?
        /// A consequence was already applied, or the stream was declared unavailable. Sticky: no later
        /// or duplicate observation can re-arm it or resurrect readiness.
        var resolved = false
    }

    private let configuration: Configuration
    private var streams: [Stream: StreamState]
    /// A route rebuild already has its own bounded retry owner. While that recovery is active, this
    /// monitor must not race it with an independent lifecycle consequence.
    private var recoveryStartedAt: TimeInterval?
    /// Set once the microphone fails: the session is ending, so every subsequent observation is inert.
    private var stopped = false

    /// `startedAt` is the session-relative origin the first-frame deadline is measured from; all later
    /// timestamps must share that monotonic clock.
    public init(configuration: Configuration = .init(),
                requiresSystemAudio: Bool = true,
                startedAt: TimeInterval) {
        self.configuration = configuration
        streams = [
            .microphone: StreamState(required: true, firstFrameWaitingSince: startedAt),
            .system: StreamState(
                required: requiresSystemAudio, firstFrameWaitingSince: startedAt),
        ]
    }

    /// Whether this stream has delivered at least one positive-sample callback.
    public func hasFirstFrame(_ stream: Stream) -> Bool {
        streams[stream]?.firstFrame == true
    }

    /// Fold app-owned provider connection state into the Core readiness decision. Reconnects can make
    /// a provider temporarily unready without discarding already-proven capture health.
    public func setProviderReady(_ ready: Bool, for stream: Stream) {
        guard !stopped, var state = streams[stream], !state.resolved else { return }
        state.providerReady = ready
        streams[stream] = state
    }

    /// Full listening requires both ready providers and both healthy frame paths. Once the system
    /// stream is explicitly unavailable, a healthy ready microphone remains usable in degraded mode.
    public var readiness: Readiness {
        guard !stopped else { return .stopped }
        guard let microphone = streams[.microphone],
              microphone.providerReady, microphone.firstFrame else {
            return .waitingForMicrophone
        }
        guard let system = streams[.system] else { return .waitingForSystem }
        if !system.required || system.resolved { return .microphoneOnly }
        return system.providerReady && system.firstFrame ? .ready : .waitingForSystem
    }

    /// Whether the system stream has been ruled unavailable (a capture consequence or an out-of-band
    /// degrade), so the caller shows microphone-only rather than waiting on system audio.
    public var isSystemUnavailable: Bool {
        streams[.system]?.resolved == true
    }

    /// Fold one capture heartbeat into this stream's health and advance time-based policy. This is
    /// the critical, in-memory branch: it reads the heartbeat value directly and never reads the
    /// evidence queue or a persisted file. Late or duplicate heartbeats after a stream is resolved
    /// (or after the microphone failed) are inert.
    @discardableResult
    public func note(
        _ heartbeat: CaptureHeartbeat, for stream: Stream, at time: TimeInterval
    ) -> [Effect] {
        guard !stopped, var state = streams[stream], !state.resolved else { return [] }
        switch heartbeat {
        case .frames(let sampleCount):
            precondition(sampleCount >= 0)
            if sampleCount > 0 {
                state.firstFrame = true
                state.stalledSince = nil
            }
        case .stalled:
            if state.stalledSince == nil { state.stalledSince = time }
        }
        streams[stream] = state
        return poll(at: time)
    }

    /// Suspend capture consequences while the aggregate device owns a bounded route-rebuild
    /// incident. A pending first-frame deadline or a witness-confirmed stall gets a complete window
    /// after recovery finishes rather than firing immediately from the pre-rebuild gap. Short rebuilds
    /// do not invent a stall; the witness remains the authority for whether established flow stopped.
    public func setCaptureRecoveryInProgress(_ inProgress: Bool, at time: TimeInterval) {
        guard !stopped else { return }
        if inProgress {
            if recoveryStartedAt == nil { recoveryStartedAt = time }
            return
        }
        guard recoveryStartedAt != nil else { return }
        self.recoveryStartedAt = nil
        for stream in Stream.allCases {
            guard var state = streams[stream], state.required, !state.resolved else { continue }
            if state.firstFrame, state.stalledSince != nil {
                state.stalledSince = time
            } else if !state.firstFrame {
                state.firstFrameWaitingSince = time
                state.stalledSince = nil
            }
            streams[stream] = state
        }
    }

    /// Declare the system stream unavailable for a reason outside capture (e.g. its transcription
    /// endpoint gave up). Stops any pending capture timeout from also firing for it.
    public func systemBecameUnavailable() {
        guard var state = streams[.system], !state.resolved else { return }
        state.resolved = true
        state.required = false
        state.providerReady = false
        streams[.system] = state
    }

    /// Advance the initial first-frame deadline and the sustained-stall deadline after frame flow has
    /// begun. Returns at most one effect; a microphone failure supersedes any system degradation on
    /// the same tick.
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
        guard recoveryStartedAt == nil else { return nil }
        guard let state = streams[stream], state.required, !state.resolved else { return nil }
        if !state.firstFrame {
            return time - state.firstFrameWaitingSince >= configuration.firstFrameTimeout
                ? .firstFrameTimeout : nil
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
        state.providerReady = false
        streams[stream] = state
    }
}
