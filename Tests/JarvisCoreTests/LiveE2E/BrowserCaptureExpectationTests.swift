import Foundation
import Testing
@testable import JarvisCore

@Suite struct BrowserCaptureExpectationTests {
    private let fullFile = "def total(values):\n    # keep repeats\n    return sum(values)"

    @Test func completeAccessibilityTextSatisfiesExactFileExpectation() throws {
        let expectation = try makeExpectation()
        let snapshot = snapshot("src/total.py\n\(fullFile)")
        #expect(expectation.failures(in: snapshot).isEmpty)
    }

    @Test func startAndEndWithoutTheMiddleDoNotPass() throws {
        let expectation = try makeExpectation()
        let snapshot = snapshot("src/total.py\ndef total(values):\n    return sum(values)")
        #expect(!expectation.failures(in: snapshot).isEmpty)
    }

    @Test func ocrCannotSubstituteForMissingAccessibility() throws {
        let expectation = try makeExpectation()
        let snapshot = snapshot("src/total.py\n\(fullFile)", source: .onDeviceOCR)
        #expect(!expectation.failures(in: snapshot).isEmpty)
    }

    @Test func truncatedTextCannotClaimFullCapture() throws {
        let expectation = try makeExpectation()
        #expect(!expectation.failures(in: snapshot("src/total.py\n\(fullFile)", truncated: true)).isEmpty)
    }

    @Test func aDifferentFileOrChangedWhitespaceFails() throws {
        let expectation = try makeExpectation()
        #expect(!expectation.failures(in: snapshot("src/other.py\n\(fullFile)")).isEmpty)
        #expect(!expectation.failures(in: snapshot("src/total.py\n" + fullFile.replacingOccurrences(of: "    ", with: " "))).isEmpty)
    }

    @Test func otherTabContentAndMissingCaptureFail() throws {
        let expectation = try makeExpectation()
        #expect(!expectation.failures(in: snapshot("src/total.py\n\(fullFile)\nOTHER_TAB_SECRET")).isEmpty)
        #expect(!expectation.failures(in: nil).isEmpty)
    }

    @Test func evidenceFromSeparateCapturesCannotBeStitchedByTheCheck() throws {
        let expectation = try makeExpectation()
        #expect(!expectation.failures(in: snapshot("src/total.py\ndef total(values):")).isEmpty)
        #expect(!expectation.failures(in: snapshot("    # keep repeats\n    return sum(values)")).isEmpty)
    }

    @Test func emptyExpectationsAreRejected() throws {
        for required in [[], [""]] as [[String]] {
            let data = try JSONSerialization.data(withJSONObject: ["requiredText": required, "forbiddenText": []])
            #expect(throws: (any Error).self) { try BrowserCaptureExpectation.decode(data) }
        }
    }

    private func makeExpectation() throws -> BrowserCaptureExpectation {
        let data = try JSONSerialization.data(withJSONObject: [
            "requiredText": ["src/total.py", fullFile], "forbiddenText": ["OTHER_TAB_SECRET"]])
        return try BrowserCaptureExpectation.decode(data)
    }

    private func snapshot(_ text: String, source: ScreenTextEvidence.Source = .browserAccessibility,
                          truncated: Bool = false) -> ScreenSnapshot {
        ScreenSnapshot(imageBase64: "fixture", textEvidence: [ScreenTextEvidence(
            text: text, source: source,
            coverage: source == .browserAccessibility ? .activeTabAccessibilityTree : .currentViewport,
            truncated: truncated)])
    }
}
