import Foundation

/// What one screen capture produced: the JPEG the brain will look at, plus — for window-scoped
/// captures — an on-device OCR of that same image, so the model can read exact text instead of
/// deciphering pixels (reasoning models are far stronger on text; see wiki/decisions.md).
public struct ScreenSnapshot: Sendable, Equatable {
    /// Monotonic time when capture began. The visual monitor uses this content-free ordering token
    /// to avoid letting an older, slow brain request acknowledge a screen change observed later.
    public let capturedAt: TimeInterval
    /// Base64-encoded JPEG produced by the capture edge.
    public let imageBase64: String
    /// Reading-ordered OCR of the captured image, or nil when unavailable (full-display fallback
    /// captures skip OCR — a whole display's text would feed the clutter back as tokens — and
    /// recognition can fail). Derived from the screen, so it goes only where the image goes.
    public let recognizedText: String?
    /// Content-free token used only by the local change monitor to suppress duplicate full captures.
    /// The capture edge derives it in memory from normalized OCR (including whole-display OCR that
    /// is intentionally not sent to the model). It is never written to the activity/traffic logs.
    public let changeFingerprint: String?
    /// Local perceptual image hash used alongside OCR so diagrams, highlighting, and OCR-missed
    /// edits remain detectable. It contains no pixels and is never sent to the model or logs.
    public let visualFingerprint: UInt64?

    public init(capturedAt: TimeInterval = ProcessInfo.processInfo.systemUptime,
                imageBase64: String, recognizedText: String? = nil,
                changeFingerprint: String? = nil, visualFingerprint: UInt64? = nil) {
        self.capturedAt = capturedAt
        self.imageBase64 = imageBase64
        self.recognizedText = recognizedText
        self.changeFingerprint = changeFingerprint
        self.visualFingerprint = visualFingerprint
    }

    /// Capture time orders monitor acknowledgements; it is not part of screenshot content identity.
    public static func == (lhs: ScreenSnapshot, rhs: ScreenSnapshot) -> Bool {
        lhs.imageBase64 == rhs.imageBase64
            && lhs.recognizedText == rhs.recognizedText
            && lhs.changeFingerprint == rhs.changeFingerprint
            && lhs.visualFingerprint == rhs.visualFingerprint
    }
}
