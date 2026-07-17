import Testing
import Foundation
@testable import JarvisCore

@Suite struct ScreenCapturePreferencesTests {
    /// A fresh, isolated UserDefaults suite per test so nothing touches the real app domain.
    private func freshDefaults() -> UserDefaults {
        let suite = "ScreenCapturePreferencesTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func defaultsToMainDisplayWhenUnset() {
        #expect(ScreenCapturePreferences(defaults: freshDefaults()).displayIndex == 1)
    }

    @Test func roundTripsThroughDefaults() {
        let d = freshDefaults()
        ScreenCapturePreferences(defaults: d).displayIndex = 2
        #expect(ScreenCapturePreferences(defaults: d).displayIndex == 2)
    }

    @Test func invalidStoredValueFallsBackToMainDisplay() {
        // A hand-edited or corrupted value must never reach `screencapture -D` as 0 or negative.
        let d = freshDefaults()
        d.set(-3, forKey: "screen.captureDisplayIndex")
        #expect(ScreenCapturePreferences(defaults: d).displayIndex == 1)
        d.set("not a number", forKey: "screen.captureDisplayIndex")
        #expect(ScreenCapturePreferences(defaults: d).displayIndex == 1)
    }

    @Test func setterClampsBelowOneToMainDisplay() {
        let p = ScreenCapturePreferences(defaults: freshDefaults())
        p.displayIndex = 0
        #expect(p.displayIndex == 1)
    }

    @Test func scopeDefaultsToActiveWindowWhenUnset() {
        #expect(ScreenCapturePreferences(defaults: freshDefaults()).scope == .activeWindow)
    }

    @Test func scopeRoundTripsThroughDefaults() {
        let d = freshDefaults()
        ScreenCapturePreferences(defaults: d).scope = .entireDisplay
        #expect(ScreenCapturePreferences(defaults: d).scope == .entireDisplay)
    }

    @Test func unrecognizedStoredScopeFallsBackToActiveWindow() {
        // A hand-edited or stale value must never crash or silently mean "entire display".
        let d = freshDefaults()
        d.set("holographic", forKey: "screen.captureScope")
        #expect(ScreenCapturePreferences(defaults: d).scope == .activeWindow)
    }

    @Test func entireDisplayScopeTargetsTheChosenDisplay() {
        let p = ScreenCapturePreferences(defaults: freshDefaults())
        p.scope = .entireDisplay
        p.displayIndex = 2
        #expect(p.explicitDisplay == 2)
    }

    @Test func mainDisplayNeedsNoExplicitTargeting() {
        // A plain capture IS the main display, so index 1 never produces a -D.
        let p = ScreenCapturePreferences(defaults: freshDefaults())
        p.scope = .entireDisplay
        p.displayIndex = 1
        #expect(p.explicitDisplay == nil)
    }

    @Test func activeWindowFallbacksIgnoreAStaleDisplayIndex() {
        // An index left over from an old entire-display selection must not steer fallbacks.
        let p = ScreenCapturePreferences(defaults: freshDefaults())
        p.scope = .activeWindow
        p.displayIndex = 3
        #expect(p.explicitDisplay == nil)
    }
}
