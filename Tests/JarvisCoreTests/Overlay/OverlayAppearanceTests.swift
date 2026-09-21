import Testing
import Foundation
@testable import JarvisCore

@Suite struct OverlayAppearanceTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "OverlayAppearanceTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func detailAppearancePersistsIndependentlyAndRejectsNonfiniteValues() {
        let defaults = freshDefaults()
        let appearance = OverlayAppearance(defaults: defaults)
        #expect(appearance.detailFontSize == Defaults.Overlay.Detail.fontSize)
        #expect(appearance.detailBackgroundOpacity == Defaults.Overlay.Detail.opacity)
        appearance.detailFontSize = 14
        appearance.detailBackgroundOpacity = 0.2
        appearance.boxFontSize = 30
        appearance.boxOpacity = 0.9
        let restored = OverlayAppearance(defaults: defaults)
        #expect(restored.detailFontSize == 14)
        #expect(restored.detailBackgroundOpacity == 0.2)
        restored.detailFontSize = .nan
        restored.detailBackgroundOpacity = .infinity
        #expect(restored.detailFontSize == Defaults.Overlay.Detail.fontSize)
        #expect(restored.detailBackgroundOpacity == Defaults.Overlay.Detail.opacity)
        restored.detailFontSize = 0
        restored.detailBackgroundOpacity = -1
        #expect(restored.detailFontSize == Defaults.Overlay.Detail.fontSizeRange.lowerBound)
        #expect(restored.detailBackgroundOpacity == Defaults.Overlay.Detail.opacityRange.lowerBound)
    }

    @Test func defaultsWhenUnset() {
        let a = OverlayAppearance(defaults: freshDefaults())
        #expect(a.boxOpacity == Defaults.Overlay.Box.opacity)
        #expect(a.boxFontSize == Defaults.Overlay.Box.fontSize)
    }

    @Test func enabledDefaults() {
        let a = OverlayAppearance(defaults: freshDefaults())
        #expect(a.boxEnabled == Defaults.Overlay.Box.enabled)
        #expect(a.boxEnabled == true)
        #expect(a.boxWidth == Defaults.Overlay.Box.width)
        #expect(a.boxHeight == Defaults.Overlay.Box.height)
    }

    @Test func roundTripsThroughDefaults() {
        let d = freshDefaults()
        OverlayAppearance(defaults: d).boxOpacity = 0.6
        OverlayAppearance(defaults: d).boxFontSize = 20
        OverlayAppearance(defaults: d).boxEnabled = false
        OverlayAppearance(defaults: d).boxWidth = 512
        OverlayAppearance(defaults: d).boxHeight = 448
        let reloaded = OverlayAppearance(defaults: d)
        #expect(reloaded.boxOpacity == 0.6)
        #expect(reloaded.boxFontSize == 20)
        #expect(reloaded.boxEnabled == false)
        #expect(reloaded.boxWidth == 512)
        #expect(reloaded.boxHeight == 448)
    }

    @Test func clampsOutOfRange() {
        let a = OverlayAppearance(defaults: freshDefaults())
        a.boxOpacity = 999
        a.boxFontSize = 999
        a.boxWidth = 99_999
        a.boxHeight = 99_999
        #expect(a.boxWidth == Defaults.Overlay.Box.widthRange.upperBound)
        #expect(a.boxHeight == Defaults.Overlay.Box.heightRange.upperBound)
        #expect(a.boxOpacity == Defaults.Overlay.Box.opacityRange.upperBound)
        #expect(a.boxFontSize == Defaults.Overlay.Box.fontSizeRange.upperBound)

        a.boxOpacity = 0
        a.boxFontSize = 1
        a.boxWidth = 0
        a.boxHeight = 0
        #expect(a.boxWidth == Defaults.Overlay.Box.widthRange.lowerBound)
        #expect(a.boxHeight == Defaults.Overlay.Box.heightRange.lowerBound)
        #expect(a.boxOpacity == Defaults.Overlay.Box.opacityRange.lowerBound)
        #expect(a.boxFontSize == Defaults.Overlay.Box.fontSizeRange.lowerBound)
    }

    @Test func nonFiniteInputFallsBackToTheDefault() {
        // Not the lower bound: with an opacity floor of 0 that would hide the surface.
        let a = OverlayAppearance(defaults: freshDefaults())
        for bad in [Double.nan, .infinity, -.infinity] {
            a.boxOpacity = bad
            a.boxWidth = bad
            a.boxHeight = bad
            #expect(a.boxOpacity == Defaults.Overlay.Box.opacity)
            #expect(a.boxWidth == Defaults.Overlay.Box.width)
            #expect(a.boxHeight == Defaults.Overlay.Box.height)
        }
    }

    @Test func fullyTransparentOpacityIsPersistable() {
        let d = freshDefaults()
        OverlayAppearance(defaults: d).boxOpacity = 0
        let reloaded = OverlayAppearance(defaults: d)
        #expect(reloaded.boxOpacity == 0)
    }
}
