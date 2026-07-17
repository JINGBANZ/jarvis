import Testing
@testable import JarvisCore

@Suite struct ScreenChangeDetectorTests {
    private func snapshot(_ text: String? = nil, image: String = "image-a",
                          visual: UInt64? = nil) -> ScreenSnapshot {
        ScreenSnapshot(imageBase64: image, recognizedText: text, visualFingerprint: visual)
    }

    @Test func remainsDormantUntilExplicitlySeeded() {
        var detector = ScreenChangeDetector()

        #expect(detector.poll(snapshot("question")) == .dormant)
        #expect(detector.poll(snapshot("question")) == .dormant)
        #expect(!detector.isSeeded)
    }

    @Test func firstLocalPollCanSeedWithoutReportingAChange() {
        var detector = ScreenChangeDetector()

        let didSeed = detector.seedIfNeeded(snapshot("blank editor"))
        #expect(didSeed)
        #expect(detector.isSeeded)
        #expect(detector.poll(snapshot("blank editor")) == .unchanged)
        let didReseed = detector.seedIfNeeded(snapshot("question appeared"))
        #expect(!didReseed)
        #expect(detector.poll(snapshot("question appeared")) == .waitingForStability)
    }

    @Test func normalizedOCRWhitespaceDoesNotCountAsAChange() {
        var detector = ScreenChangeDetector()
        detector.observe(snapshot("class  Solution {\n    return answer;\n}"))

        #expect(detector.poll(snapshot(" class Solution { return answer; } ")) == .unchanged)
    }

    @Test func changingCandidatesCoalesceUntilOneRemainsStable() {
        var detector = ScreenChangeDetector(requiredStablePollCount: 2)
        detector.observe(snapshot("// waiting for question"))

        #expect(detector.poll(snapshot("Given an array")) == .waitingForStability)
        #expect(detector.poll(snapshot("Given an array of integers")) == .waitingForStability)
        #expect(detector.poll(snapshot("Given an array of integers")) == .stableChange)
    }

    @Test func stableStateEmitsOnceWhileAwaitingCoachAcknowledgement() {
        var detector = ScreenChangeDetector()
        detector.observe(snapshot("before"))

        #expect(detector.poll(snapshot("after")) == .waitingForStability)
        #expect(detector.poll(snapshot("after")) == .stableChange)
        #expect(detector.poll(snapshot("after")) == .awaitingAcknowledgement)

        detector.observe(snapshot("after"))
        #expect(detector.poll(snapshot("after")) == .unchanged)
    }

    @Test func newerStableCandidateCanReplaceOneStillAwaitingAcknowledgement() {
        var detector = ScreenChangeDetector()
        detector.observe(snapshot("before"))

        #expect(detector.poll(snapshot("partially typed")) == .waitingForStability)
        #expect(detector.poll(snapshot("partially typed")) == .stableChange)
        #expect(detector.poll(snapshot("finished solution")) == .waitingForStability)
        #expect(detector.poll(snapshot("finished solution")) == .stableChange)
    }

    @Test func failedDeliveryRearmsTheSameStableCandidate() {
        var detector = ScreenChangeDetector()
        detector.observe(snapshot("before"))

        #expect(detector.poll(snapshot("question")) == .waitingForStability)
        #expect(detector.poll(snapshot("question")) == .stableChange)
        #expect(detector.poll(snapshot("question")) == .awaitingAcknowledgement)

        detector.retryUnacknowledgedChange()
        #expect(detector.poll(snapshot("question")) == .stableChange)
    }

    @Test func preservesCodeSensitiveCaseAndPunctuation() {
        var detector = ScreenChangeDetector()
        detector.observe(snapshot("return value"))

        #expect(detector.poll(snapshot("return Value;")) == .waitingForStability)
        #expect(detector.poll(snapshot("return Value;")) == .stableChange)
    }

    @Test func sameOCRWithDifferentVisualContentStillCountsAsAChange() {
        var detector = ScreenChangeDetector(requiredStablePollCount: 1)
        detector.observe(snapshot("same OCR", visual: 0x0000_0000_0000_0000))

        #expect(detector.poll(snapshot("same OCR", visual: 0xFFFF_FFFF_FFFF_FFFF))
                == .stableChange)
    }

    @Test func smallPerceptualHashDriftDoesNotCreateScreenNoise() {
        var detector = ScreenChangeDetector(requiredStablePollCount: 1)
        detector.observe(snapshot("same OCR", visual: 0))

        #expect(detector.poll(snapshot("same OCR", visual: 0b1111_1111)) == .unchanged)
    }

    @Test func fallsBackToTheImageWhenOCRIsUnavailableOrEmpty() {
        var detector = ScreenChangeDetector()
        detector.observe(snapshot(nil, image: "jpeg-a"))
        #expect(detector.poll(snapshot(nil, image: "jpeg-a")) == .unchanged)
        #expect(detector.poll(snapshot("   \n", image: "jpeg-b")) == .waitingForStability)
        #expect(detector.poll(snapshot("   \n", image: "jpeg-b")) == .stableChange)
    }

    @Test func observingARealCaptureReplacesBaselineAndPendingCandidate() {
        var detector = ScreenChangeDetector()
        detector.observe(snapshot("old screen"))
        #expect(detector.poll(snapshot("partially typed")) == .waitingForStability)

        detector.observe(snapshot("coach saw this"))
        #expect(detector.poll(snapshot("coach saw this")) == .unchanged)
        #expect(detector.poll(snapshot("partially typed")) == .waitingForStability)

        detector.reset()
        #expect(detector.poll(snapshot("partially typed")) == .dormant)
    }
}
