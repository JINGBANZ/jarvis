import Testing
@testable import JarvisCore

@Suite struct ScreenTextEvidenceTests {
    @Test func exposesWhenSourceTextWasBounded() {
        let evidence = ScreenTextEvidence(
            text: "partial question",
            source: .browserAccessibility,
            coverage: .activeTabAccessibilityTree,
            truncated: true)

        #expect(evidence.truncated)
    }
}
