import Testing
@testable import JarvisCore

@Suite struct BrowserChromeCropTests {
    @Test func chromeRemovesTabStripAndToolbarAtOnePixelPerPoint() {
        let inset = BrowserChromeCrop.topInsetPixels(
            bundleIdentifier: "com.google.Chrome",
            imageWidth: 1_937,
            imageHeight: 1_317,
            windowWidthPoints: 1_937)
        #expect(inset == 82)
    }

    @Test func insetTracksRetinaBackingScale() {
        let inset = BrowserChromeCrop.topInsetPixels(
            bundleIdentifier: "com.google.Chrome.canary",
            imageWidth: 2_000,
            imageHeight: 1_400,
            windowWidthPoints: 1_000)
        #expect(inset == 164)
    }

    @Test func chromiumUsesTheSameContentBoundary() {
        let inset = BrowserChromeCrop.topInsetPixels(
            bundleIdentifier: "org.chromium.Chromium",
            imageWidth: 1_200,
            imageHeight: 800,
            windowWidthPoints: 1_200)
        #expect(inset == 82)
    }

    @Test func unknownAppsRemainUncropped() {
        let inset = BrowserChromeCrop.topInsetPixels(
            bundleIdentifier: "com.apple.Safari",
            imageWidth: 1_200,
            imageHeight: 800,
            windowWidthPoints: 1_200)
        #expect(inset == nil)
    }

    @Test func invalidGeometryRemainsUncropped() {
        let inset = BrowserChromeCrop.topInsetPixels(
            bundleIdentifier: "com.google.Chrome",
            imageWidth: 1_200,
            imageHeight: 80,
            windowWidthPoints: 1_200)
        #expect(inset == nil)
    }
}
