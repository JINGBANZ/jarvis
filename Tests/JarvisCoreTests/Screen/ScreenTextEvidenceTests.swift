import Testing
@testable import JarvisCore

@Suite struct ScreenTextEvidenceTests {
    @Test func onlyBrowserAccessibilityEvidenceIsRetainable() {
        #expect(ScreenTextEvidence(
            text: "question",
            source: .browserAccessibility,
            coverage: .activeTabAccessibilityTree
        ).isRetainable)
        #expect(!ScreenTextEvidence(
            text: "question",
            source: .onDeviceOCR,
            coverage: .currentViewport
        ).isRetainable)
    }
}
