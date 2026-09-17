import Foundation

public struct ScreenSnapshot: Sendable, Equatable {
    /// Base64-encoded JPEG.
    public let imageBase64: String
    /// Screen-derived, so it may go only where the image goes.
    public let textEvidence: [ScreenTextEvidence]
    public init(
        imageBase64: String,
        textEvidence: [ScreenTextEvidence] = []
    ) {
        self.imageBase64 = imageBase64
        self.textEvidence = textEvidence
    }
}
