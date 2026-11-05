import Foundation

public protocol ScreenCapturing: Sendable {
    /// Independent cancellation for one attempt; cleanup failures remain shared across the session.
    func makeAttemptCapture() -> any ScreenCapturing
    /// Nil on failure. Shoots `selection` as given, never a re-read preference, so a capture can't
    /// change mid-attempt.
    func capture(_ selection: ScreenCaptureSelection) -> ScreenSnapshot?
    /// Cancels only this attempt, including captures that have not started. `capture()` returns
    /// only after its own helper and transient file are cleaned up.
    func cancelCapture()
}
