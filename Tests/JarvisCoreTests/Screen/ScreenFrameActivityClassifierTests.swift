import Testing
@testable import JarvisCore

@Suite struct ScreenFrameActivityClassifierTests {
    @Test func fullSurfaceBrowserRedrawWithUnchangedPixelsIsIdle() {
        var classifier = ScreenFrameActivityClassifier(minimumChangedAreaRatio: 0.01)
        let staticPage = [UInt8](repeating: 180, count: 100)

        #expect(classifier.observe(pixels: staticPage, dirtyAreaRatio: 1) == .idle)
        #expect(classifier.observe(pixels: staticPage, dirtyAreaRatio: 1) == .idle)
    }

    @Test func visibleChangeWinsEvenWhenMetadataClaimsAFullRedraw() {
        var classifier = ScreenFrameActivityClassifier(minimumChangedAreaRatio: 0.01)
        let before = [UInt8](repeating: 220, count: 100)
        var after = before
        for index in 0..<10 { after[index] = 20 }

        _ = classifier.observe(pixels: before, dirtyAreaRatio: 1)
        #expect(classifier.observe(pixels: after, dirtyAreaRatio: 1)
                == .changed(areaRatio: 0.1, evidence: .visualPixels))
    }

    @Test func boundedDirtyRegionPreservesTinyCodeEditsLostByDownsampling() {
        var classifier = ScreenFrameActivityClassifier(minimumChangedAreaRatio: 0.001)
        let pixels = [UInt8](repeating: 200, count: 100)

        _ = classifier.observe(pixels: pixels, dirtyAreaRatio: nil)
        #expect(classifier.observe(pixels: pixels, dirtyAreaRatio: 0.005)
                == .changed(areaRatio: 0.005, evidence: .boundedDirtyRegion))
    }

    @Test func largeMetadataOnlyRedrawCannotBlockVisualQuiescence() {
        var classifier = ScreenFrameActivityClassifier(minimumChangedAreaRatio: 0.001)
        let pixels = [UInt8](repeating: 200, count: 100)

        _ = classifier.observe(pixels: pixels, dirtyAreaRatio: nil)
        #expect(classifier.observe(pixels: pixels, dirtyAreaRatio: 0.9) == .idle)
    }

    @Test func subThresholdPixelNoiseIsIdle() {
        var classifier = ScreenFrameActivityClassifier(
            minimumChangedAreaRatio: 0.01, minimumPixelDelta: 16)
        let before = [UInt8](repeating: 100, count: 100)
        var after = before
        after[0] = 115

        _ = classifier.observe(pixels: before, dirtyAreaRatio: nil)
        #expect(classifier.observe(pixels: after, dirtyAreaRatio: nil) == .idle)
    }

    @Test func changedDimensionsAreAVisibleChange() {
        var classifier = ScreenFrameActivityClassifier(minimumChangedAreaRatio: 0.01)
        _ = classifier.observe(pixels: [10, 20, 30], dirtyAreaRatio: nil)

        #expect(classifier.observe(pixels: [10, 20, 30, 40], dirtyAreaRatio: nil)
                == .changed(areaRatio: 1, evidence: .visualPixels))
    }

    @Test func zeroThresholdDoesNotTurnIdenticalFramesIntoChanges() {
        var classifier = ScreenFrameActivityClassifier(minimumChangedAreaRatio: 0)
        let pixels = [UInt8](repeating: 120, count: 10)

        _ = classifier.observe(pixels: pixels, dirtyAreaRatio: 0)
        #expect(classifier.observe(pixels: pixels, dirtyAreaRatio: 0) == .idle)
    }

    @Test func highConfiguredThresholdStillInitializes() {
        var classifier = ScreenFrameActivityClassifier(minimumChangedAreaRatio: 0.5)
        let pixels = [UInt8](repeating: 120, count: 10)

        #expect(classifier.observe(pixels: pixels, dirtyAreaRatio: 1) == .idle)
    }

    @Test func visuallyStableCompleteFramesCanFinishQuiescence() {
        var classifier = ScreenFrameActivityClassifier(minimumChangedAreaRatio: 0.01)
        var detector = ScreenActivityDetector(
            quiescenceInterval: 1, minimumChangedAreaRatio: 0.01)
        let before = [UInt8](repeating: 220, count: 100)
        var after = before
        for index in 0..<10 { after[index] = 20 }

        #expect(classifier.observe(pixels: before, dirtyAreaRatio: 1) == .idle)
        let changed = classifier.observe(pixels: after, dirtyAreaRatio: 1)
        guard case .changed(let ratio, _) = changed else {
            Issue.record("Expected a visible change")
            return
        }
        #expect(detector.observe(.contentChanged(changedAreaRatio: ratio), at: 1)
                == .waitingForQuiescence)

        #expect(classifier.observe(pixels: after, dirtyAreaRatio: 1) == .idle)
        #expect(detector.observe(.idle, at: 1.5) == .waitingForQuiescence)
        #expect(classifier.observe(pixels: after, dirtyAreaRatio: 1) == .idle)
        guard case .stableChange = detector.observe(.idle, at: 2) else {
            Issue.record("Stable redraws should complete the quiet window")
            return
        }
    }
}
