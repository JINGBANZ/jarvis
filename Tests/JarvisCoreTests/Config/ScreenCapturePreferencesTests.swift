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
}
