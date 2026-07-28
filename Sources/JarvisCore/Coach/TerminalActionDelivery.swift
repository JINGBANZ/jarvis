import Foundation

/// Main-actor commit boundary for the user-visible effect of one coaching session.
///
/// Each Start owns a distinct instance. Stop invalidates that instance synchronously on the main
/// actor before cancelling the turn, so a terminal action queued by an old driver cannot write
/// Activity or reach an overlay belonging to a replacement session.
@MainActor
public final class TerminalActionDelivery {
    public typealias ActivityRecorder = @MainActor @Sendable (ActivityLog.Event) -> Void
    public typealias OverlayRenderer =
        @MainActor @Sendable (_ lines: [String], _ perLineSeconds: [TimeInterval]) -> Void
    public typealias SessionEnd = @MainActor @Sendable () -> Void

    private let recordActivity: ActivityRecorder
    private let renderOverlay: OverlayRenderer
    private let endSession: SessionEnd
    private var isActive = true

    public init(
        recordActivity: @escaping ActivityRecorder,
        renderOverlay: @escaping OverlayRenderer,
        endSession: @escaping SessionEnd = {}
    ) {
        self.recordActivity = recordActivity
        self.renderOverlay = renderOverlay
        self.endSession = endSession
    }

    /// Returns false when Stop already won the main-actor ordering race.
    @discardableResult
    public func deliver(
        _ decision: CoachingActionBroker.TerminalDecision,
        perLineSeconds: [TimeInterval] = []
    ) -> Bool {
        guard isActive else { return false }
        switch decision {
        case .speak(_, let lines):
            recordActivity(.tip(lines: lines))
            renderOverlay(lines, perLineSeconds)
        case .staySilent:
            recordActivity(.stayedSilent)
        }
        return true
    }

    /// Synchronous on the main actor: after this returns, no queued delivery through this session
    /// object can pass its liveness check.
    public func invalidate() {
        guard isActive else { return }
        isActive = false
        endSession()
    }
}
