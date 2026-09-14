import Foundation
import JarvisCore
import Testing
@testable import JarvisScreenCapture

@Suite struct ScreenTextResolverTests {
    private let window = WindowCandidate(
        windowID: 7, ownerPID: 42, layer: 0,
        x: 100, y: 200, width: 1200, height: 800)

    @Test func accessibilitySuccessAlsoRunsOCR() {
        let browser = FakeBrowserReader(result: ScreenTextEvidence(
            text: "full question",
            source: .browserAccessibility,
            coverage: .activeTabAccessibilityTree))
        let ocr = FakeImageTextRecognizer(result: "corrupted")

        let result = ScreenTextResolver(browser: browser, ocr: ocr).resolve(
            jpeg: Data(), window: window, browserDocumentIdentity: identity("document-a"))

        #expect(result == [
            ScreenTextEvidence(
                text: "full question",
                source: .browserAccessibility,
                coverage: .activeTabAccessibilityTree),
            ScreenTextEvidence(
                text: "corrupted",
                source: .onDeviceOCR,
                coverage: .currentViewport),
        ])
        #expect(browser.callCount == 1)
        #expect(ocr.callCount == 1)
    }

    @Test func emptyAccessibilityFallsBackToCurrentViewportOCR() {
        let browser = FakeBrowserReader(result: nil)
        let ocr = FakeImageTextRecognizer(result: "visible text")

        let result = ScreenTextResolver(browser: browser, ocr: ocr).resolve(
            jpeg: Data(), window: window, browserDocumentIdentity: identity("document-a"))

        #expect(result == [ScreenTextEvidence(
            text: "visible text", source: .onDeviceOCR, coverage: .currentViewport)])
        #expect(browser.callCount == 1)
        #expect(ocr.callCount == 1)
    }

    @Test func mismatchedAccessibilityCoverageFallsBackToOCR() {
        let browser = FakeBrowserReader(result: ScreenTextEvidence(
            text: "untrusted coverage",
            source: .browserAccessibility,
            coverage: .currentViewport))
        let ocr = FakeImageTextRecognizer(result: "visible text")

        let result = ScreenTextResolver(browser: browser, ocr: ocr).resolve(
            jpeg: Data(), window: window, browserDocumentIdentity: identity("document-a"))

        #expect(result == [ScreenTextEvidence(
            text: "visible text", source: .onDeviceOCR, coverage: .currentViewport)])
        #expect(ocr.callCount == 1)
    }

    @Test func disabledAccessibilityGoesStraightToOCR() {
        let browser = FakeBrowserReader(result: ScreenTextEvidence(
            text: "should not be read",
            source: .browserAccessibility,
            coverage: .activeTabAccessibilityTree))
        let ocr = FakeImageTextRecognizer(result: "visible text")

        _ = ScreenTextResolver(browser: browser, ocr: ocr).resolve(
            jpeg: Data(), window: window, browserDocumentIdentity: nil)

        #expect(browser.callCount == 0)
        #expect(ocr.callCount == 1)
    }

    @Test func emptyOCRProducesNoTextEvidence() {
        let result = ScreenTextResolver(
            browser: FakeBrowserReader(result: nil),
            ocr: FakeImageTextRecognizer(result: " \n ")
        ).resolve(jpeg: Data(), window: window, browserDocumentIdentity: identity("document-a"))

        #expect(result.isEmpty)
    }

    @Test func unavailablePreCaptureIdentityUsesOnlyScreenshotOCR() {
        let browser = FakeBrowserReader(result: ScreenTextEvidence(
            text: "different tab",
            source: .browserAccessibility,
            coverage: .activeTabAccessibilityTree))
        let ocr = FakeImageTextRecognizer(result: "captured tab")

        let result = ScreenTextResolver(browser: browser, ocr: ocr).resolve(
            jpeg: Data(), window: window, browserDocumentIdentity: nil)

        #expect(result.map(\.source) == [.onDeviceOCR])
        #expect(browser.callCount == 0)
    }

    @Test func changedPostCaptureIdentityUsesOnlyScreenshotOCR() {
        let browser = FakeBrowserReader(
            result: ScreenTextEvidence(
                text: "new tab",
                source: .browserAccessibility,
                coverage: .activeTabAccessibilityTree),
            identity: "document-b")
        let ocr = FakeImageTextRecognizer(result: "captured tab")

        let result = ScreenTextResolver(browser: browser, ocr: ocr).resolve(
            jpeg: Data(), window: window, browserDocumentIdentity: identity("document-a"))

        #expect(result == [ScreenTextEvidence(
            text: "captured tab", source: .onDeviceOCR, coverage: .currentViewport)])
        #expect(browser.callCount == 1)
    }

    private func identity(_ value: String) -> BrowserDocumentIdentity {
        BrowserDocumentIdentity(value: value, deadline: .greatestFiniteMagnitude)
    }
}

/// `result` is immutable; `lock` protects `calls` and all mutable state.
private final class FakeBrowserReader: BrowserAccessibilityReading, @unchecked Sendable {
    private let lock = NSLock()
    private let result: ScreenTextEvidence?
    private let identity: String
    private var calls = 0

    init(result: ScreenTextEvidence?, identity: String = "document-a") {
        self.result = result
        self.identity = identity
    }

    func documentIdentity(for window: WindowCandidate) -> BrowserDocumentIdentity? {
        BrowserDocumentIdentity(value: identity, deadline: .greatestFiniteMagnitude)
    }

    func readActiveTab(
        for window: WindowCandidate,
        matching documentIdentity: BrowserDocumentIdentity
    ) -> ScreenTextEvidence? {
        lock.withLock { calls += 1 }
        return documentIdentity.value == identity ? result : nil
    }

    var callCount: Int { lock.withLock { calls } }
}

/// `result` is immutable; `lock` protects `calls` and all mutable state.
private final class FakeImageTextRecognizer: ImageTextRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private let result: String?
    private var calls = 0

    init(result: String?) { self.result = result }

    func recognizedText(inJPEG jpeg: Data) -> String? {
        lock.withLock { calls += 1 }
        return result
    }

    var callCount: Int { lock.withLock { calls } }
}
