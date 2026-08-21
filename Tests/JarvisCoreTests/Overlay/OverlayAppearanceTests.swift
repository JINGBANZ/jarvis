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
        #expect(a.captionFontSize == Defaults.Overlay.Caption.fontSize)
        #expect(a.captionBackgroundOpacity == Defaults.Overlay.Caption.opacity)
        #expect(a.boxOpacity == Defaults.Overlay.Box.opacity)
        #expect(a.boxFontSize == Defaults.Overlay.Box.fontSize)
    }

    /// The two surfaces default opposite ways: the caption off, the box on.
    @Test func enabledDefaults() {
        let a = OverlayAppearance(defaults: freshDefaults())
        #expect(a.captionEnabled == Defaults.Overlay.Caption.enabled)
        #expect(a.boxEnabled == Defaults.Overlay.Box.enabled)
        #expect(a.captionEnabled == false)
        #expect(a.boxEnabled == true)
        #expect(a.boxWidth == Defaults.Overlay.Box.width)
        #expect(a.boxHeight == Defaults.Overlay.Box.height)
    }

    @Test func roundTripsThroughDefaults() {
        let d = freshDefaults()
        OverlayAppearance(defaults: d).captionFontSize = 22
        OverlayAppearance(defaults: d).captionBackgroundOpacity = 0.9
        OverlayAppearance(defaults: d).boxOpacity = 0.6
        OverlayAppearance(defaults: d).boxFontSize = 20
        OverlayAppearance(defaults: d).captionEnabled = true
        OverlayAppearance(defaults: d).boxEnabled = false
        OverlayAppearance(defaults: d).boxWidth = 512
        OverlayAppearance(defaults: d).boxHeight = 448
        let reloaded = OverlayAppearance(defaults: d)
        #expect(reloaded.captionFontSize == 22)
        #expect(reloaded.captionBackgroundOpacity == 0.9)
        #expect(reloaded.boxOpacity == 0.6)
        #expect(reloaded.boxFontSize == 20)
        #expect(reloaded.captionEnabled == true)
        #expect(reloaded.boxEnabled == false)
        // The size the user dragged the box to must survive a relaunch unchanged.
        #expect(reloaded.boxWidth == 512)
        #expect(reloaded.boxHeight == 448)
    }

    @Test func clampsOutOfRange() {
        let a = OverlayAppearance(defaults: freshDefaults())
        a.captionFontSize = 999
        a.captionBackgroundOpacity = 999
        a.boxOpacity = 999
        a.boxFontSize = 999
        a.boxWidth = 99_999
        a.boxHeight = 99_999
        #expect(a.boxWidth == Defaults.Overlay.Box.widthRange.upperBound)
        #expect(a.boxHeight == Defaults.Overlay.Box.heightRange.upperBound)
        #expect(a.captionFontSize == Defaults.Overlay.Caption.fontSizeRange.upperBound)
        #expect(a.captionBackgroundOpacity == Defaults.Overlay.Caption.opacityRange.upperBound)
        #expect(a.boxOpacity == Defaults.Overlay.Box.opacityRange.upperBound)
        #expect(a.boxFontSize == Defaults.Overlay.Box.fontSizeRange.upperBound)

        a.captionFontSize = 1
        a.captionBackgroundOpacity = 0
        a.boxOpacity = 0
        a.boxFontSize = 1
        a.boxWidth = 0
        a.boxHeight = 0
        #expect(a.boxWidth == Defaults.Overlay.Box.widthRange.lowerBound)
        #expect(a.boxHeight == Defaults.Overlay.Box.heightRange.lowerBound)
        #expect(a.captionFontSize == Defaults.Overlay.Caption.fontSizeRange.lowerBound)
        #expect(a.captionBackgroundOpacity == Defaults.Overlay.Caption.opacityRange.lowerBound)
        #expect(a.boxOpacity == Defaults.Overlay.Box.opacityRange.lowerBound)
        #expect(a.boxFontSize == Defaults.Overlay.Box.fontSizeRange.lowerBound)
    }

    @Test func nonFiniteInputFallsBackToFinite() {
        // A corrupted plist value (NaN/±inf) must never reach systemFont(ofSize:)/withAlphaComponent:.
        let a = OverlayAppearance(defaults: freshDefaults())
        for bad in [Double.nan, .infinity, -.infinity] {
            a.captionFontSize = bad
            a.captionBackgroundOpacity = bad
            #expect(a.captionFontSize.isFinite)
            #expect(a.captionBackgroundOpacity.isFinite)
            #expect(Defaults.Overlay.Caption.fontSizeRange.contains(a.captionFontSize))
            #expect(Defaults.Overlay.Caption.opacityRange.contains(a.captionBackgroundOpacity))
        }
    }
}
