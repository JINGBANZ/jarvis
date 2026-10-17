#if JARVIS_LIVE_E2E // Debug builds only: see liveE2ESettings in Package.swift
import Foundation
import JarvisCore
import os

final class FixtureScreenCapture: ScreenCapturing {
    private let recognizer = ScreenTextRecognizer()
    private let current = OSAllocatedUnfairLock<Data?>(initialState: nil)

    @MainActor
    func show(_ fixture: URL) throws {
        let jpeg = fixture.pathExtension.lowercased() == "txt"
            ? try Self.textJPEG(String(contentsOf: fixture, encoding: .utf8))
            : try Data(contentsOf: fixture)
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

    func cancelCapture() {}
}
#endif
