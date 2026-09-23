import Foundation

/// Local silence only requests finalization. A pass settles once the analyzer completes and its
/// results are consumed. Newer speech forces another pass once that speech ends.
public struct TranscriptionFinalizationState: Sendable {
    public struct Token: Equatable, Hashable, Sendable {
        fileprivate let revision: UInt64
    }

    public struct Effects: Equatable, Sendable {
        public static let none = Effects()

        /// Nil when the published work state is unchanged.
        public let work: TranscriptionWorkState?
        /// The pass to run now, or nil.
        public let finalization: Token?
        public let completedFinalization: Token?

        fileprivate init(
            work: TranscriptionWorkState? = nil,
            finalization: Token? = nil,
            completedFinalization: Token? = nil
        ) {
            self.work = work
            self.finalization = finalization
            self.completedFinalization = completedFinalization
        }
    }

    private struct FinalizationPass: Sendable {
        let token: Token
        var analyzerCompleted = false
        var resultsConsumed = false
    }

    private var speechIsActive = false
    private var needsFinalization = false
    private var finalizationInFlight: FinalizationPass?
    private var nextRevision: UInt64 = 0
    /// Session-relative onset of the oldest speech no pass has settled yet. It holds until the pass
    /// settles, so a phrase finalized mid-sentence still waits for the rest of the sentence.
    private var pendingSpeechStart: TimeInterval?
    private var publishedWork: TranscriptionWorkState = .settled
    public private(set) var hasPendingWork = false

    public init() {}

    public mutating func recordSpeechStarted(at start: TimeInterval) -> Effects {
        speechIsActive = true
        // If setup was delayed, the next end finalizes all input through the newer episode.
        if finalizationInFlight == nil { needsFinalization = false }
        if !hasPendingWork {
            hasPendingWork = true
            pendingSpeechStart = start.isFinite && start >= 0 ? start : nil
        }
        return publish()
    }

    public mutating func recordSpeechEnded(analyzerAvailable: Bool) -> Effects {
        speechIsActive = false
        needsFinalization = true
        hasPendingWork = true
        return publish(finalization: beginFinalization(analyzerAvailable: analyzerAvailable))
    }

    /// Setup can complete after buffered speech has already ended.
    public mutating func analyzerBecameAvailable() -> Effects {
        publish(finalization: beginFinalization(analyzerAvailable: true))
    }

    public mutating func analyzerFinalizationCompleted(
        _ token: Token,
        analyzerAvailable: Bool
    ) -> Effects {
        guard finalizationInFlight?.token == token else { return .none }
        finalizationInFlight?.analyzerCompleted = true
        return finishFinalizationIfPossible(analyzerAvailable: analyzerAvailable)
    }

    /// May arrive before or after `analyzerFinalizationCompleted`.
    public mutating func finalResultsConsumed(
        _ token: Token,
        analyzerAvailable: Bool
    ) -> Effects {
        guard finalizationInFlight?.token == token else { return .none }
        finalizationInFlight?.resultsConsumed = true
        return finishFinalizationIfPossible(analyzerAvailable: analyzerAvailable)
    }

    @discardableResult
    public mutating func reset() -> Effects {
        speechIsActive = false
        needsFinalization = false
        finalizationInFlight = nil
        hasPendingWork = false
        pendingSpeechStart = nil
        return publish()
    }

    private var currentWork: TranscriptionWorkState {
        hasPendingWork ? .pending(since: pendingSpeechStart) : .settled
    }

    private mutating func publish(
        finalization: Token? = nil,
        completedFinalization: Token? = nil
    ) -> Effects {
        let work = currentWork
        guard work != publishedWork else {
            return .init(finalization: finalization, completedFinalization: completedFinalization)
        }
        publishedWork = work
        return .init(
            work: work,
            finalization: finalization,
            completedFinalization: completedFinalization)
    }

    private mutating func beginFinalization(analyzerAvailable: Bool) -> Token? {
        guard analyzerAvailable, !speechIsActive, needsFinalization,
              finalizationInFlight == nil else { return nil }
        nextRevision &+= 1
        let token = Token(revision: nextRevision)
        finalizationInFlight = FinalizationPass(token: token)
        needsFinalization = false
        return token
    }

    private mutating func finishFinalizationIfPossible(
        analyzerAvailable: Bool
    ) -> Effects {
        guard let pass = finalizationInFlight,
              pass.analyzerCompleted, pass.resultsConsumed else { return .none }
        finalizationInFlight = nil
        let next = beginFinalization(analyzerAvailable: analyzerAvailable)
        if next == nil, !speechIsActive {
            hasPendingWork = false
            pendingSpeechStart = nil
        }
        return publish(finalization: next, completedFinalization: pass.token)
    }
}
