import Foundation

public protocol ScreenCapturing: Sendable {
    /// Nil on failure. Shoots `selection` as given, never a re-read preference, so a capture can't
    /// change mid-attempt.
    func capture(_ selection: ScreenCaptureSelection) -> ScreenSnapshot?
    /// `capture()` must return only after its helper and transient file are cleaned up.
    func cancelCapture()
}
