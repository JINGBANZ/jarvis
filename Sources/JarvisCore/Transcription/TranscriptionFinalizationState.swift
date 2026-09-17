import Foundation

/// Local silence only requests finalization. A pass settles once the analyzer completes and its
/// results are consumed. Newer speech forces another pass once that speech ends.
public struct TranscriptionFinalizationState: Sendable {
    public struct Token: Equatable, Hashable, Sendable {
        fileprivate let revision: UInt64
    }

    public struct Effects: Equatable, Sendable {
        public static let none = Effects()

        /// Nil when unchanged.
        public let pendingWork: Bool?
        /// The pass to run now, or nil.
        public let finalization: Token?
        public let completedFinalization: Token?

        fileprivate init(
            pendingWork: Bool? = nil,
            finalization: Token? = nil,
            completedFinalization: Token? = nil
        ) {
            self.pendingWork = pendingWork
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
    public private(set) var hasPendingWork = false

    public init() {}

    public mutating func recordSpeechStarted() -> Effects {
        speechIsActive = true
        // If setup was delayed, the next end finalizes all input through the newer episode.
        if finalizationInFlight == nil { needsFinalization = false }
        guard !hasPendingWork else { return .init() }
        hasPendingWork = true
        return .init(pendingWork: true)
    }

    public mutating func recordSpeechEnded(analyzerAvailable: Bool) -> Effects {
        speechIsActive = false
        needsFinalization = true
        let publishPending = hasPendingWork ? nil : true
        hasPendingWork = true
        return beginFinalizationIfPossible(
            analyzerAvailable: analyzerAvailable,
            pendingWork: publishPending)
    }

    /// Setup can complete after buffered speech has already ended.
    public mutating func analyzerBecameAvailable() -> Effects {
        beginFinalizationIfPossible(analyzerAvailable: true)
    }

    public mutating func analyzerFinalizationCompleted(
        _ token: Token,
        analyzerAvailable: Bool
    ) -> Effects {
        guard finalizationInFlight?.token == token else { return .init() }
        finalizationInFlight?.analyzerCompleted = true
        return finishFinalizationIfPossible(analyzerAvailable: analyzerAvailable)
    }

    /// May arrive before or after `analyzerFinalizationCompleted`.
    public mutating func finalResultsConsumed(
        _ token: Token,
        analyzerAvailable: Bool
    ) -> Effects {
        guard finalizationInFlight?.token == token else { return .init() }
        finalizationInFlight?.resultsConsumed = true
        return finishFinalizationIfPossible(analyzerAvailable: analyzerAvailable)
    }

    @discardableResult
    public mutating func reset() -> Effects {
        let publishSettled = hasPendingWork ? false : nil
        speechIsActive = false
        needsFinalization = false
        finalizationInFlight = nil
        hasPendingWork = false
        return .init(pendingWork: publishSettled)
    }

    private mutating func beginFinalizationIfPossible(
        analyzerAvailable: Bool,
        pendingWork: Bool? = nil
    ) -> Effects {
        guard analyzerAvailable, !speechIsActive, needsFinalization,
              finalizationInFlight == nil else {
            return .init(pendingWork: pendingWork)
        }
        nextRevision &+= 1
        let token = Token(revision: nextRevision)
        finalizationInFlight = FinalizationPass(token: token)
        needsFinalization = false
        return .init(pendingWork: pendingWork, finalization: token)
    }

    private mutating func finishFinalizationIfPossible(
        analyzerAvailable: Bool
    ) -> Effects {
        guard let pass = finalizationInFlight,
              pass.analyzerCompleted, pass.resultsConsumed else { return .init() }
        finalizationInFlight = nil
        let next = speechIsActive
            ? Effects.none
            : beginFinalizationIfPossible(analyzerAvailable: analyzerAvailable)
        if next.finalization != nil {
            return .init(
                pendingWork: next.pendingWork,
                finalization: next.finalization,
                completedFinalization: pass.token)
        }
        guard !speechIsActive, hasPendingWork else {
            return .init(completedFinalization: pass.token)
        }
        hasPendingWork = false
        return .init(pendingWork: false, completedFinalization: pass.token)
    }
}
