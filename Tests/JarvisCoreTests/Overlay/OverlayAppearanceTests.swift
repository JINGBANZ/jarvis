import Testing
import Foundation
@testable import JarvisCore

@Suite struct OverlayAppearanceTests {
    /// A fresh, isolated UserDefaults suite per test so nothing touches the real app domain.
    private func freshDefaults() -> UserDefaults {
        let suite = "OverlayAppearanceTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func defaultsWhenUnset() {
        let a = OverlayAppearance(defaults: freshDefaults())
        #expect(a.fontSize == Config.overlayFontSizeDefault)
        #expect(a.backgroundOpacity == Config.overlayOpacityDefault)
    }

    @Test func roundTripsThroughDefaults() {
        let d = freshDefaults()
        OverlayAppearance(defaults: d).fontSize = 22
        OverlayAppearance(defaults: d).backgroundOpacity = 0.9
        let reloaded = OverlayAppearance(defaults: d)
        #expect(reloaded.fontSize == 22)
        #expect(reloaded.backgroundOpacity == 0.9)
    }

    @Test func clampsOutOfRange() {
        let a = OverlayAppearance(defaults: freshDefaults())
        a.fontSize = 999
        a.backgroundOpacity = 999
        #expect(a.fontSize == Config.overlayFontSizeRange.upperBound)
        #expect(a.backgroundOpacity == Config.overlayOpacityRange.upperBound)

        a.fontSize = 1
        a.backgroundOpacity = 0
        #expect(a.fontSize == Config.overlayFontSizeRange.lowerBound)
        #expect(a.backgroundOpacity == Config.overlayOpacityRange.lowerBound)
    }

    @Test func nonFiniteInputFallsBackToFinite() {
        // A corrupted plist value (NaN/±inf) must never reach systemFont(ofSize:)/withAlphaComponent:.
        let a = OverlayAppearance(defaults: freshDefaults())
        for bad in [Double.nan, .infinity, -.infinity] {
            a.fontSize = bad
            a.backgroundOpacity = bad
            #expect(a.fontSize.isFinite)
            #expect(a.backgroundOpacity.isFinite)
            #expect(Config.overlayFontSizeRange.contains(a.fontSize))
            #expect(Config.overlayOpacityRange.contains(a.backgroundOpacity))
        }
    }
}
