import Testing
@testable import JarvisCore

@Suite struct FrontWindowSelectorTests {
    private let ownPID = 999

    private func window(_ id: Int, pid: Int = 42, layer: Int = 0,
                        width: Double = 1200, height: Double = 800) -> WindowCandidate {
        WindowCandidate(windowID: id, ownerPID: pid, layer: layer, width: width, height: height)
    }

    @Test func picksTheFrontmostOrdinaryWindow() {
        let id = FrontWindowSelector.frontWindowID(
            in: [window(7), window(8, pid: 43)], ownPID: ownPID)
        #expect(id == 7)
    }

    /// The dock, menu bar, and floating panels ride at non-zero layers ahead of app windows in the
    /// list — they must never be "the window the user works in".
    @Test func skipsNonZeroLayers() {
        let id = FrontWindowSelector.frontWindowID(
            in: [window(1, layer: 25), window(2, layer: 20), window(3)], ownPID: ownPID)
        #expect(id == 3)
    }

    /// Jarvis's own Settings window frontmost (the user just tweaked a setting, then hit the hint
    /// hotkey): the pick is the user's previously active window right under it.
    @Test func skipsOwnWindowsAndPicksTheOneBeneath() {
        let id = FrontWindowSelector.frontWindowID(
            in: [window(1, pid: ownPID), window(2, pid: 42)], ownPID: ownPID)
        #expect(id == 2)
    }

    /// Status bubbles and 1-pt helper windows sit at layer 0 too; a shot of one is useless.
    @Test func skipsTinyLayerZeroWindows() {
        let id = FrontWindowSelector.frontWindowID(
            in: [window(1, width: 320, height: 24), window(2)], ownPID: ownPID)
        #expect(id == 2)
    }

    /// Bare desktop (or a transiently empty list): nil, so the caller falls back to full-display.
    @Test func returnsNilWhenNothingEligible() {
        #expect(FrontWindowSelector.frontWindowID(in: [], ownPID: ownPID) == nil)
        #expect(FrontWindowSelector.frontWindowID(
            in: [window(1, pid: ownPID), window(2, layer: 25)], ownPID: ownPID) == nil)
    }
}
