import Foundation
import JarvisCore

public protocol ImageTextRecognizing: Sendable {
    func recognizedText(inJPEG jpeg: Data) -> String?
}

/// Runs both sources: Accessibility reaches beyond the viewport, while OCR covers pixels that
/// virtualized editors and canvases omit.
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
        browserDocumentIdentity: BrowserDocumentIdentity?
    ) -> [ScreenTextEvidence] {
        var evidence: [ScreenTextEvidence] = []
        if let browserDocumentIdentity,
           let browserEvidence = browser.readActiveTab(
               for: window,
               matching: browserDocumentIdentity),
           browserEvidence.source == .browserAccessibility,
           browserEvidence.coverage == .activeTabAccessibilityTree,
           !browserEvidence.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            evidence.append(browserEvidence)
        }

        if let text = ocr.recognizedText(inJPEG: jpeg),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            evidence.append(ScreenTextEvidence(
                text: text,
                source: .onDeviceOCR,
                coverage: .currentViewport))
        }
        return evidence
    }

    public func browserDocumentIdentity(for window: WindowCandidate) -> BrowserDocumentIdentity? {
        browser.documentIdentity(for: window)
    }
}
