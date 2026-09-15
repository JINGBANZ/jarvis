#if JARVIS_LIVE_E2E // Debug builds only: see liveE2ESettings in Package.swift
import Foundation
import JarvisCore
import os

/// A `ScreenCapturing` port that returns the scenario's current fixture image instead of shooting the
/// Mac's front window, so a developer can keep using the Mac while a live e2e run goes.
///
/// On-device OCR rides along as current-viewport text evidence, from the same recognizer the window
/// path uses, so the coach receives the snapshot shape production sends for a non-browser window.
/// Before a scenario's first `screen` step there is no image, and a capture returns nil, as a failed
/// production capture does.
final class FixtureScreenCapture: ScreenCapturing {
    private let recognizer = ScreenTextRecognizer()
    private let current = OSAllocatedUnfairLock<Data?>(initialState: nil)

    /// Put a JPEG on the injected screen; every later capture returns it until the next call.
    func show(_ jpeg: Data) {
        current.withLock { $0 = jpeg }
    }

    func capture(_ selection: ScreenCaptureSelection) -> ScreenSnapshot? {
        guard let jpeg = current.withLock({ $0 }) else { return nil }
        let text = recognizer.recognizedText(inJPEG: jpeg)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ScreenSnapshot(
            imageBase64: jpeg.base64EncodedString(),
            textEvidence: text.flatMap { $0.isEmpty ? nil : $0 }.map {
                [ScreenTextEvidence(text: $0, source: .onDeviceOCR, coverage: .currentViewport)]
            } ?? [])
    }

    /// No helper process or transient file exists to clean up.
    func cancelCapture() {}
}
#endif
