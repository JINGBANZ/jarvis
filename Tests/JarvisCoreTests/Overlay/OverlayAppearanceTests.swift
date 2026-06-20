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
        #expect(a.responseBoxOpacity == Config.responseBoxOpacityDefault)
        #expect(a.responseBoxFontSize == Config.responseBoxFontSizeDefault)
    }

    @Test func roundTripsThroughDefaults() {
        let d = freshDefaults()
        OverlayAppearance(defaults: d).fontSize = 22
        OverlayAppearance(defaults: d).backgroundOpacity = 0.9
        OverlayAppearance(defaults: d).responseBoxOpacity = 0.6
        OverlayAppearance(defaults: d).responseBoxFontSize = 20
        let reloaded = OverlayAppearance(defaults: d)
        #expect(reloaded.fontSize == 22)
        #expect(reloaded.backgroundOpacity == 0.9)
        #expect(reloaded.responseBoxOpacity == 0.6)
        #expect(reloaded.responseBoxFontSize == 20)
    }

    @Test func clampsOutOfRange() {
        let a = OverlayAppearance(defaults: freshDefaults())
        a.fontSize = 999
        a.backgroundOpacity = 999
        a.responseBoxOpacity = 999
        a.responseBoxFontSize = 999
        #expect(a.fontSize == Config.overlayFontSizeRange.upperBound)
        #expect(a.backgroundOpacity == Config.overlayOpacityRange.upperBound)
        #expect(a.responseBoxOpacity == Config.responseBoxOpacityRange.upperBound)
        #expect(a.responseBoxFontSize == Config.responseBoxFontSizeRange.upperBound)

        a.fontSize = 1
        a.backgroundOpacity = 0
        a.responseBoxOpacity = 0
        a.responseBoxFontSize = 1
        #expect(a.fontSize == Config.overlayFontSizeRange.lowerBound)
        #expect(a.backgroundOpacity == Config.overlayOpacityRange.lowerBound)
        #expect(a.responseBoxOpacity == Config.responseBoxOpacityRange.lowerBound)
        #expect(a.responseBoxFontSize == Config.responseBoxFontSizeRange.lowerBound)
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
