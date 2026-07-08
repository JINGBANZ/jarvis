import Foundation

/// Picks the window a window-scoped `capture_screen` should shoot: the frontmost ordinary window
/// that isn't Jarvis's own.
///
/// macOS keeps ONE z-order across all displays, and exactly one window system-wide is the key
/// window receiving keystrokes — so "first eligible window in the front-to-back list" is the
/// window the user last clicked or typed into, whichever monitor it lives on. When Jarvis itself
/// is frontmost (its Settings window), the own-PID filter lands on the user's previously active
/// window — which is what a hint is about.
public enum FrontWindowSelector {
    /// Skips layer-0 sub-window droppings (status bubbles, 1-pt helper windows) that would make a
    /// useless screenshot. Points, not pixels — window-server bounds are in points.
    private static let minimumDimension: Double = 100

    /// `candidates` must be in front-to-back z-order (as `CGWindowListCopyWindowInfo` returns).
    /// Returns nil when nothing eligible is on screen — callers fall back to full-display capture.
    public static func frontWindowID(in candidates: [WindowCandidate], ownPID: Int) -> Int? {
        candidates.first {
            $0.layer == 0 && $0.ownerPID != ownPID
                && $0.width >= minimumDimension && $0.height >= minimumDimension
        }?.windowID
    }
}
