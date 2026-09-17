import Testing
import Foundation
@testable import JarvisCore

@Suite struct ScreenCapturePreferencesTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "ScreenCapturePreferencesTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func defaultsToMainDisplayWhenUnset() {
        #expect(ScreenCapturePreferences(defaults: freshDefaults()).displayIndex
            == Defaults.Screen.displayIndex)
    }

    @Test func roundTripsThroughDefaults() {
        let d = freshDefaults()
        ScreenCapturePreferences(defaults: d).displayIndex = 2
        #expect(ScreenCapturePreferences(defaults: d).displayIndex == 2)
    }

    @Test func invalidStoredValueFallsBackToMainDisplay() {
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
        let p = ScreenCapturePreferences(defaults: freshDefaults())
        p.scope = .entireDisplay
        p.displayIndex = 1
        #expect(p.explicitDisplay == nil)
    }

    @Test func activeWindowFallbacksIgnoreAStaleDisplayIndex() {
        let p = ScreenCapturePreferences(defaults: freshDefaults())
        p.scope = .activeWindow
        p.displayIndex = 3
        #expect(p.explicitDisplay == nil)
    }

    @Test func browserTextDefaultsOffAndRoundTripsThroughDefaults() {
        let d = freshDefaults()
        #expect(!ScreenCapturePreferences(defaults: d).browserTextEnabled)
        ScreenCapturePreferences(defaults: d).browserTextEnabled = true
        #expect(ScreenCapturePreferences(defaults: d).browserTextEnabled)
    }

    @Test func revokedBrowserTextAvailabilityClearsPersistedOptIn() {
        let preferences = ScreenCapturePreferences(defaults: freshDefaults())
        preferences.browserTextEnabled = true

        #expect(preferences.reconcileBrowserTextAvailability(isAvailable: false))
        #expect(!preferences.browserTextEnabled)
    }

    @Test func availableBrowserTextPreservesPersistedOptIn() {
        let preferences = ScreenCapturePreferences(defaults: freshDefaults())
        preferences.browserTextEnabled = true

        #expect(!preferences.reconcileBrowserTextAvailability(isAvailable: true))
        #expect(preferences.browserTextEnabled)
    }
}
