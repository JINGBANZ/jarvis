import Foundation

/// One on-screen window as reported by the window server, listed front-to-back. Plain values only,
/// so `FrontWindowSelector`'s rule stays Foundation-only and unit-testable; the `CGWindowList` dump
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
