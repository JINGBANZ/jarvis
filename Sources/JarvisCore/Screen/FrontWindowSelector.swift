import Foundation

/// macOS keeps one z-order across all displays, so the first eligible window is the one the user
/// last used on any monitor. Skipping Jarvis's PID lands on the user's window behind Settings.
public enum FrontWindowSelector {
    /// Points, not pixels. Skips layer-0 helper windows too small to be a useful screenshot.
    private static let minimumDimension: Double = 100

    /// `candidates` must be in front-to-back order. Nil when nothing on screen is eligible.
    public static func frontWindow(in candidates: [WindowCandidate], ownPID: Int) -> WindowCandidate? {
        candidates.first {
            $0.layer == 0 && $0.ownerPID != ownPID
                && $0.width >= minimumDimension && $0.height >= minimumDimension
        }
    }
}
