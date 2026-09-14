import Foundation
import JarvisCore

public protocol ImageTextRecognizing: Sendable {
    func recognizedText(inJPEG jpeg: Data) -> String?
}

/// Chooses one text sidecar for an active-window screenshot. Browser semantics win when the user
/// opted in and the exact foreground tab yields text; every other path performs OCR once.
public struct ScreenTextResolver: Sendable {
    private let browser: any BrowserAccessibilityReading
    private let ocr: any ImageTextRecognizing

    public init(browser: any BrowserAccessibilityReading, ocr: any ImageTextRecognizing) {
        self.browser = browser
        self.ocr = ocr
    }

    public func resolve(
        jpeg: Data,
        window: WindowCandidate,
        browserTextEnabled: Bool
    ) -> ScreenTextEvidence? {
        if browserTextEnabled,
           let evidence = browser.readActiveTab(for: window),
           evidence.source == .browserAccessibility,
           !evidence.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return evidence
        }

        guard let text = ocr.recognizedText(inJPEG: jpeg),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return ScreenTextEvidence(
            text: text,
            source: .onDeviceOCR,
            coverage: .currentViewport)
    }
}
