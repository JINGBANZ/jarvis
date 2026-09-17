import Foundation

public final class JarvisReadiness {
    /// Observations name their attempt, so callbacks queued across Stop and Start
    /// cannot mutate the replacement session.
    public struct Session: Sendable, Hashable {
        fileprivate let generation: UInt64
    }

    /// Declaration order is the order notices name them, so a message never reshuffles.
    public enum Permission: String, Sendable, Hashable, CaseIterable {
        case microphone
        /// macOS has no API to request or read the process-tap grant, so the only evidence is an
        /// adapter having started a tap-backed device.
        case systemAudio
        case screenRecording

        /// The names macOS uses in System Settings.
        public var displayName: String {
            switch self {
            case .microphone: "Microphone"
            case .systemAudio: "System Audio Recording"
            case .screenRecording: "Screen Recording"
            }
        }
    }

    public enum Requirement: Sendable, Equatable {
        case permissions
        case credentials
        case brainPreparation
        case brainResponse(BrainProvider)
        case transcriptionPreparation
        case transcriptionEndpoints
        case capture
    }

    public enum ReadyMode: Sendable, Equatable {
        case full
        case microphoneOnly
    }

    public enum BrainBlocker: Sendable, Equatable {
        case providerUnavailable
    }

    public enum TranscriptionBlocker: Sendable, Equatable {
        case unavailable
        case preparationFailed
    }

    public enum Blocker: Sendable, Equatable {
        case permissions(Set<Permission>)
        case credentials(Set<Credential>)
        case brain(BrainBlocker)
        case transcription(TranscriptionBlocker)
        case endpoint(CaptureReadinessMonitor.Stream)
        case capture(CaptureReadinessMonitor.Stream)
    }

    public enum Status: Sendable, Equatable {
        case checking(Requirement)
        case blocked(Blocker)
        case recovering(Requirement, attempt: Int?)
        case ready(ReadyMode)
        case cycleFailed(BrainProvider)
        case stopped
    }

    public enum BrainPreparation: Sendable, Equatable {
        case preparing
        case ready
        case blocked(BrainBlocker)
    }

    public enum TranscriptionPreparation: Sendable, Equatable {
        case preparing
        case ready
        case blocked(TranscriptionBlocker)
    }

    public enum Observation: Sendable, Equatable {
        case permissions(granted: Set<Permission>)
        case credentials(available: Set<Credential>)
        case brainPreparation(BrainPreparation)
        case transcriptionPreparation(TranscriptionPreparation)
        case transcriptionEndpoint(
            stream: CaptureReadinessMonitor.Stream,
            state: TranscriptionConnectionState
        )
        case capture(CaptureReadinessMonitor.Readiness)
        case captureRecovery(inProgress: Bool)
        case brainRecovery(BrainProvider?)
        case brainCycleFailed(BrainProvider)
    }

    public enum Effect: Sendable, Equatable {
        case statusChanged(Status)
        case readinessEstablished(ReadyMode)
    }

    public struct Configuration: Sendable, Equatable {
        public let requiredPermissions: Set<Permission>
        public let requiredCredentials: Set<Credential>
        public let requiresBrainPreparation: Bool
        public let requiresTranscriptionPreparation: Bool
        public let requiresSystemAudio: Bool

        public init(
            requiredPermissions: Set<Permission> = [.microphone, .systemAudio, .screenRecording],
            requiredCredentials: Set<Credential> = [],
            requiresBrainPreparation: Bool = true,
            requiresTranscriptionPreparation: Bool = false,
            requiresSystemAudio: Bool = true
        ) {
            self.requiredPermissions = requiredPermissions
            self.requiredCredentials = requiredCredentials
            self.requiresBrainPreparation = requiresBrainPreparation
            self.requiresTranscriptionPreparation = requiresTranscriptionPreparation
            self.requiresSystemAudio = requiresSystemAudio
        }
    }

    private enum CheckState {
        case pending
        case satisfied
        case blocked(Blocker)
    }

    public private(set) var status: Status = .stopped

    private var nextGeneration: UInt64 = 0
    /// Nil once stopped. The app reads this rather than keeping its own copy of the token.
    public private(set) var activeSession: Session?
    private var configuration = Configuration()
    private var permissionState: CheckState = .satisfied
    private var credentialState: CheckState = .satisfied
    private var brainState: CheckState = .satisfied
    private var transcriptionPreparationState: CheckState = .satisfied
    private var endpointStates: [CaptureReadinessMonitor.Stream: TranscriptionConnectionState] = [:]
    private var captureState: CaptureReadinessMonitor.Readiness?
    private var captureRecoveryInProgress = false
    private var recoveringBrain: BrainProvider?
    /// Independent of higher-priority capture status so caption streak suppression remains stable.
    public var hasFailedCoachingCycle: Bool { failedBrain != nil }
    private var failedBrain: BrainProvider?

    public init() {}

    @discardableResult
    public func begin(configuration: Configuration) -> (session: Session, effects: [Effect]) {
        nextGeneration &+= 1
        let session = Session(generation: nextGeneration)
        activeSession = session
        self.configuration = configuration
        permissionState = configuration.requiredPermissions.isEmpty ? .satisfied : .pending
        credentialState = configuration.requiredCredentials.isEmpty ? .satisfied : .pending
        brainState = configuration.requiresBrainPreparation ? .pending : .satisfied
        transcriptionPreparationState = configuration.requiresTranscriptionPreparation
            ? .pending : .satisfied
        endpointStates = [:]
        captureState = nil
        captureRecoveryInProgress = false
        recoveringBrain = nil
        failedBrain = nil
        return (session, transition(to: reducedStatus()))
    }

    @discardableResult
    public func observe(_ observation: Observation, for session: Session) -> [Effect] {
        observe([observation], for: session)
    }

    /// Stale, post-Stop, and post-block observations are inert; a blocker needs a fresh Start.
    @discardableResult
    public func observe(_ observations: [Observation], for session: Session) -> [Effect] {
        guard activeSession == session, !Self.isBlocked(status) else { return [] }
        for observation in observations {
            apply(observation)
        }
        return transition(to: reducedStatus())
    }

    /// No later observation carrying this token can leave Stopped.
    @discardableResult
    public func stop(session: Session) -> [Effect] {
        guard activeSession == session else { return [] }
        activeSession = nil
        captureRecoveryInProgress = false
        return transition(to: .stopped)
    }

    private func apply(_ observation: Observation) {
        switch observation {
        case .permissions(let granted):
            let missing = configuration.requiredPermissions.subtracting(granted)
            permissionState = missing.isEmpty ? .satisfied : .blocked(.permissions(missing))

        case .credentials(let available):
            let missing = configuration.requiredCredentials.subtracting(available)
            credentialState = missing.isEmpty ? .satisfied : .blocked(.credentials(missing))

        case .brainPreparation(let preparation):
            switch preparation {
            case .preparing:
                brainState = .pending
            case .ready:
                brainState = .satisfied
            case .blocked(let blocker):
                brainState = .blocked(.brain(blocker))
            }

        case .transcriptionPreparation(let preparation):
            switch preparation {
            case .preparing:
                transcriptionPreparationState = .pending
            case .ready:
                transcriptionPreparationState = .satisfied
            case .blocked(let blocker):
                transcriptionPreparationState = .blocked(.transcription(blocker))
            }

        case .transcriptionEndpoint(let stream, let state):
            endpointStates[stream] = state

        case .capture(let readiness):
            captureState = readiness

        case .captureRecovery(let inProgress):
            captureRecoveryInProgress = inProgress

        case .brainRecovery(let provider):
            recoveringBrain = provider
            if provider == nil { failedBrain = nil }
        case .brainCycleFailed(let provider):
            recoveringBrain = nil
            failedBrain = provider
        }
    }

    private func reducedStatus() -> Status {
        for state in [permissionState, credentialState, brainState, transcriptionPreparationState] {
            if case .blocked(let blocker) = state { return .blocked(blocker) }
        }

        if let microphone = endpointStates[.microphone],
           microphone == .failed || microphone == .stopped {
            return .blocked(.endpoint(.microphone))
        }
        if captureState == .stopped {
            return .blocked(.capture(.microphone))
        }

        if captureRecoveryInProgress {
            return .recovering(.capture, attempt: nil)
        }
        if case .reconnecting(let attempt) = endpointStates[.microphone] {
            return .recovering(.transcriptionEndpoints, attempt: attempt)
        }
        if configuration.requiresSystemAudio,
           captureState != .microphoneOnly,
           case .reconnecting(let attempt) = endpointStates[.system] {
            return .recovering(.transcriptionEndpoints, attempt: attempt)
        }

        let orderedChecks: [(Requirement, CheckState)] = [
            (.permissions, permissionState),
            (.credentials, credentialState),
            (.brainPreparation, brainState),
            (.transcriptionPreparation, transcriptionPreparationState),
        ]
        if let pending = orderedChecks.first(where: {
            if case .pending = $0.1 { return true }
            return false
        }) {
            return .checking(pending.0)
        }

        guard endpointStates[.microphone] == .ready else {
            return .checking(.transcriptionEndpoints)
        }
        if configuration.requiresSystemAudio, captureState != .microphoneOnly,
           endpointStates[.system] != .ready {
            return .checking(.transcriptionEndpoints)
        }

        if let failedBrain { return .cycleFailed(failedBrain) }
        if let recoveringBrain {
            return .recovering(.brainResponse(recoveringBrain), attempt: nil)
        }

        switch captureState {
        case .ready:
            return configuration.requiresSystemAudio
                ? .ready(.full) : .ready(.microphoneOnly)
        case .microphoneOnly:
            return .ready(.microphoneOnly)
        case .waitingForMicrophone, .waitingForSystem, nil:
            return .checking(.capture)
        case .stopped:
            // Unreachable: handled above so the blocked cause remains typed.
            return .blocked(.capture(.microphone))
        }
    }

    private func transition(to next: Status) -> [Effect] {
        let previous = status
        guard next != previous else { return [] }
        status = next
        var effects: [Effect] = [.statusChanged(next)]
        if case .ready(let mode) = next, !Self.isReady(previous) {
            effects.append(.readinessEstablished(mode))
        }
        return effects
    }

    private static func isReady(_ status: Status) -> Bool {
        if case .ready = status { return true }
        return false
    }

    private static func isBlocked(_ status: Status) -> Bool {
        if case .blocked = status { return true }
        return false
    }
}
