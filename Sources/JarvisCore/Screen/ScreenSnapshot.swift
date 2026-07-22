import Foundation

/// What one screen capture produced: the JPEG the brain will look at, plus — for window-scoped
/// captures — an on-device OCR of that same image, so the model can read exact text instead of
/// deciphering pixels (reasoning models are far stronger on text; see wiki/decisions.md).
public struct ScreenSnapshot: Sendable, Equatable {
    /// Base64-encoded JPEG, as `screencapture` produced it.
    public let imageBase64: String
    /// Reading-ordered OCR of the captured image, or nil when unavailable (full-display fallback
    /// captures skip OCR — a whole display's text would feed the clutter back as tokens — and
    /// recognition can fail). Derived from the screen, so it goes only where the image goes.
    public let recognizedText: String?

    public init(imageBase64: String, recognizedText: String? = nil) {
        self.imageBase64 = imageBase64
        self.recognizedText = recognizedText
    }
}
