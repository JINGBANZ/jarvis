import Foundation

/// One on-screen window as reported by the window server, listed front-to-back. Plain values only,
/// so the selection rule below stays Foundation-only and unit-testable; the `CGWindowList` dump
/// that produces these lives in JarvisApp (`WindowScopedScreenCapture`).
public struct WindowCandidate: Sendable, Equatable {
    public let windowID: Int
    public let ownerPID: Int
    /// The CGWindow level: 0 is an ordinary app window. The dock, menu bar, and floating panels
    /// (including Jarvis's own overlay) sit on other levels.
    public let layer: Int
    public let width: Double
    public let height: Double

    public init(windowID: Int, ownerPID: Int, layer: Int, width: Double, height: Double) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.layer = layer
        self.width = width
        self.height = height
    }
}

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
