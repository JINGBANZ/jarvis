import Testing
@testable import JarvisCore

@Suite struct FrontWindowSelectorTests {
    private let ownPID = 999

    private func window(_ id: Int, pid: Int = 42, layer: Int = 0,
                        x: Double = 0, y: Double = 0,
                        width: Double = 1200, height: Double = 800) -> WindowCandidate {
        WindowCandidate(windowID: id, ownerPID: pid, layer: layer,
                        x: x, y: y, width: width, height: height)
    }

    @Test func returnsTheSelectedWindowIdentityAndBounds() {
        let expected = window(7, x: 100, y: 200)
        #expect(FrontWindowSelector.frontWindow(in: [expected], ownPID: ownPID) == expected)
    }

    @Test func picksTheFrontmostOrdinaryWindow() {
        let selected = FrontWindowSelector.frontWindow(
            in: [window(7), window(8, pid: 43)], ownPID: ownPID)
        #expect(selected?.windowID == 7)
    }

    /// The Dock, menu bar, and floating panels sit at non-zero layers.
    @Test func skipsNonZeroLayers() {
        let selected = FrontWindowSelector.frontWindow(
            in: [window(1, layer: 25), window(2, layer: 20), window(3)], ownPID: ownPID)
        #expect(selected?.windowID == 3)
    }

    @Test func skipsOwnWindowsAndPicksTheOneBeneath() {
        let selected = FrontWindowSelector.frontWindow(
            in: [window(1, pid: ownPID), window(2, pid: 42)], ownPID: ownPID)
        #expect(selected?.windowID == 2)
    }

    /// Status bubbles and 1 pt helper windows also sit at layer 0.
    @Test func skipsTinyLayerZeroWindows() {
        let selected = FrontWindowSelector.frontWindow(
            in: [window(1, width: 320, height: 24), window(2)], ownPID: ownPID)
        #expect(selected?.windowID == 2)
    }

    @Test func returnsNilWhenNothingEligible() {
        #expect(FrontWindowSelector.frontWindow(in: [], ownPID: ownPID) == nil)
        #expect(FrontWindowSelector.frontWindow(
            in: [window(1, pid: ownPID), window(2, layer: 25)], ownPID: ownPID) == nil)
    }
}
