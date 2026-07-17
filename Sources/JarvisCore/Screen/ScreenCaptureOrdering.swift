import Foundation

/// Decides whether a successfully consumed screenshot is fresh enough to acknowledge local screen
/// activity. Monitor-owned snapshots use candidate IDs to reconcile later changes; an ordinary
/// screenshot may acknowledge only changes observed no later than when its capture began.
public enum ScreenCaptureOrdering {
    public static func canAcknowledge(
        capturedAt: TimeInterval,
        latestObservedChangeAt: TimeInterval?,
        isMonitorSnapshot: Bool
    ) -> Bool {
        precondition(capturedAt.isFinite)
        precondition(latestObservedChangeAt?.isFinite != false)
        return isMonitorSnapshot
            || latestObservedChangeAt.map { capturedAt >= $0 } != false
    }
}
