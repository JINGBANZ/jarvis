import Foundation

/// Returns a screenshot (plus optional OCR text) for the brain, or nil on failure.
///
/// This is the kernel's screen port: Core owns the contract and the pure selection/layout logic
/// behind it, while the concrete `screencapture` helper, its transient session-local JPEG, and the
/// cleanup-verification latch live at the macOS edge (`JarvisScreenCapture`'s `ScreenCaptureRunner`
/// / `ScreenCaptureCLI`, composed by `WindowScopedScreenCapture` in JarvisApp).
public protocol ScreenCapturing: Sendable {
    func capture() -> ScreenSnapshot?
    /// Stop an in-flight capture and make `capture()` return only after its helper and transient
    /// file have been cleaned up.
    func cancelCapture()
}
