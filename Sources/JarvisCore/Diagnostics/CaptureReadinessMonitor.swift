import Foundation

/// Readiness counts frame arrival, never amplitude, so digital silence is healthy capture.
public final class CaptureReadinessMonitor {
    public enum Stream: String, Sendable, Equatable, CaseIterable {
        case microphone
        case system
    }

    public enum Readiness: Sendable, Equatable {
        case waitingForMicrophone
        case waitingForSystem
        case ready
        case microphoneOnly
        case stopped
    }

    public enum FailureCause: String, Sendable, Equatable {
        case firstFrameTimeout
        case sustainedStall

        /// Activity copy. The raw values are debug-log identifiers, not prose.
        public var summary: String {
            switch self {
            case .firstFrameTimeout: return "it never started arriving"
            case .sustainedStall: return "it stopped arriving"
            }
        }
    }

    /// The caller must apply these. Both are silent, ghost-safe outcomes.
    public enum Effect: Sendable, Equatable {
        /// Terminal: coaching must stop.
        case microphoneCaptureFailed(FailureCause)
        case degradeToMicrophoneOnly(FailureCause)
    }

    public struct Configuration: Sendable, Equatable {
        public let firstFrameTimeout: TimeInterval
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
        /// Sticky: no later or duplicate observation can re-arm it or resurrect readiness.
        var resolved = false
    }

    private let configuration: Configuration
    private var streams: [Stream: StreamState]
    /// A route rebuild has its own bounded retry owner, so no consequence may race it.
    private var recoveryStartedAt: TimeInterval?
    private var stopped = false

    /// `startedAt` and every later timestamp must share one monotonic clock.
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

    public func hasFirstFrame(_ stream: Stream) -> Bool {
        streams[stream]?.firstFrame == true
    }

    /// A reconnect can unready a provider without discarding proven capture health.
    public func setProviderReady(_ ready: Bool, for stream: Stream) {
        guard !stopped, var state = streams[stream], !state.resolved else { return }
        state.providerReady = ready
        streams[stream] = state
    }

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

    public var isSystemUnavailable: Bool {
        streams[.system]?.resolved == true
    }

    /// Stays in memory: never reads the evidence queue or a persisted file.
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

    /// After recovery, a pending deadline or stall restarts its full window instead of firing.
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

    public func systemBecameUnavailable() {
        guard var state = streams[.system], !state.resolved else { return }
        state.resolved = true
        state.required = false
        state.providerReady = false
        streams[.system] = state
    }

    /// Returns at most one effect; a microphone failure supersedes system degradation.
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
