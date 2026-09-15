import Foundation
import JarvisCore
import os

/// A `ScreenCapturing` port that returns the scenario's current fixture image instead of shooting the
/// Mac's front window, so a developer can keep using the Mac while a live e2e run goes.
///
/// The recognized text rides along the way the window path attaches it, from the same on-device
/// recognizer, so the coach receives the snapshot shape production sends. Before a scenario's first
/// `screen` step there is no image, and a capture returns nil, as a failed production capture does.
final class FixtureScreenCapture: ScreenCapturing {
    private let recognizer = ScreenTextRecognizer()
    private let current = OSAllocatedUnfairLock<Data?>(initialState: nil)

    /// Put a JPEG on the injected screen; every later capture returns it until the next call.
    func show(_ jpeg: Data) {
        current.withLock { $0 = jpeg }
    }

    func capture(_ selection: ScreenCaptureSelection) -> ScreenSnapshot? {
        guard let jpeg = current.withLock({ $0 }) else { return nil }
        return ScreenSnapshot(
            imageBase64: jpeg.base64EncodedString(),
            recognizedText: recognizer.recognizedText(inJPEG: jpeg))
    }

    /// No helper process or transient file exists to clean up.
    func cancelCapture() {}
}
