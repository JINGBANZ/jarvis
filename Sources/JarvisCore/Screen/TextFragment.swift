import Foundation

/// Normalized box with a top-left origin, so smaller `minY` is higher. Vision's bottom-left origin
/// must be flipped before building one.
public struct TextFragment: Sendable, Equatable {
    public let string: String
    public let minX: Double
    public let minY: Double
    public let width: Double
    public let height: Double

    public init(string: String, minX: Double, minY: Double, width: Double, height: Double) {
        self.string = string
        self.minX = minX
        self.minY = minY
        self.width = width
        self.height = height
    }
}
