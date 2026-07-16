import Testing
@testable import JarvisCore

@Suite struct ScreenCaptureCLITests {
    @Test func entireDisplayScopeTargetsTheChosenDisplay() {
        #expect(ScreenCaptureCLI.arguments(scope: .entireDisplay, displayIndex: 2)
            == ["-x", "-t", "jpg", "-D", "2"])
    }

    @Test func mainDisplayNeedsNoDashD() {
        #expect(ScreenCaptureCLI.arguments(scope: .entireDisplay, displayIndex: 1)
            == ["-x", "-t", "jpg"])
    }

    @Test func activeWindowFallbackIgnoresAStaleDisplayIndex() {
        #expect(ScreenCaptureCLI.arguments(scope: .activeWindow, displayIndex: 3)
            == ["-x", "-t", "jpg"])
    }
}
