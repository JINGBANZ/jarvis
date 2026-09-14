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
        #expect(!ScreenTextEvidence(
            text: "question",
            source: .browserAccessibility,
            coverage: .currentViewport
        ).isRetainable)
    }

    @Test func exposesWhenSourceTextWasBounded() {
        let evidence = ScreenTextEvidence(
            text: "partial question",
            source: .browserAccessibility,
            coverage: .activeTabAccessibilityTree,
            truncated: true)

        #expect(evidence.truncated)
    }
}
