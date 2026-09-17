import Foundation

public struct WindowCandidate: Sendable, Equatable {
    public let windowID: Int
    public let ownerPID: Int
    /// CGWindow level; 0 is an ordinary app window.
    public let layer: Int
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(
        windowID: Int,
        ownerPID: Int,
        layer: Int,
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.layer = layer
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
