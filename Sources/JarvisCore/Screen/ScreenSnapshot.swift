import Foundation

/// What one screen capture produced: the JPEG the brain will look at plus optional typed text
/// evidence from the same foreground context.
public struct ScreenSnapshot: Sendable, Equatable {
    /// Base64-encoded JPEG, as `screencapture` produced it.
    public let imageBase64: String
    /// Source- and coverage-labeled text, or nil when unavailable. Derived from the screen, so it
    /// goes only where the image goes.
    public let textEvidence: ScreenTextEvidence?
    /// Capture origin only; a window can show many documents. Never use this as file identity.
    public let sourceID: String?

    public init(
        imageBase64: String,
        textEvidence: ScreenTextEvidence? = nil,
        sourceID: String? = nil
    ) {
        self.imageBase64 = imageBase64
        self.textEvidence = textEvidence
        self.sourceID = sourceID
    }
}
