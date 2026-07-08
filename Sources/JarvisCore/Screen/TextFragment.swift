import Foundation

/// One OCR'd run of text and its normalized bounding box, top-left origin (y grows downward, so
/// smaller `minY` = higher on screen). The Vision edge in JarvisApp flips from Vision's
/// bottom-left origin before handing fragments to `RecognizedTextLayout`.
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
