import Foundation

/// What one screen capture produced: the JPEG the brain will look at plus optional typed text
/// evidence from the same foreground context.
public struct ScreenSnapshot: Sendable, Equatable {
    /// Base64-encoded JPEG, as `screencapture` produced it.
    public let imageBase64: String
    /// Source- and coverage-labeled text. Accessibility and OCR are complementary, so an active
    /// Chrome capture may contain both. Derived from the screen, so it goes only where the image goes.
    public let textEvidence: [ScreenTextEvidence]
    public init(
        imageBase64: String,
        textEvidence: [ScreenTextEvidence] = []
    ) {
        self.imageBase64 = imageBase64
        self.textEvidence = textEvidence
    }
}
