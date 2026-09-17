import Testing
import AppKit
@testable import JarvisOverlay

@Suite struct OverlayBoxChromeTests {

    @Test
    func theSmallestBoxStillGetsAnAimableHeader() {
        let chrome = OverlayBoxChrome(contentHeight: 140)   // Defaults.Overlay.Box.heightRange floor
        #expect(chrome.height == 26, "the header must not shrink below a clickable strip")
        #expect(chrome.titlePointSize == 11)
        #expect(chrome.button == 18)
        #expect(chrome.inset == 4)
    }

    @Test
    func theDefaultBoxScalesTheHeaderUp() {
        let chrome = OverlayBoxChrome(contentHeight: 440)   // Defaults.Overlay.Box.height
        #expect(chrome.height == 33)
        #expect(chrome.titlePointSize == 15)
        #expect(chrome.iconPointSize == 17)
        #expect(chrome.button == 25)
        #expect(chrome.inset == 6)
    }

    @Test
    func aTallBoxStopsGrowingTheHeader() {
        let chrome = OverlayBoxChrome(contentHeight: 4096)  // the range's ceiling
        #expect(chrome.height == 44, "past the cap the strip is chrome, not a banner")
        #expect(chrome.titlePointSize == 19)
    }

    @Test
    func everyPartFitsInsideTheStripAtEveryHeight() {
        for height in stride(from: CGFloat(140), through: 4096, by: 37) {
            let chrome = OverlayBoxChrome(contentHeight: height)
            #expect(chrome.button < chrome.height, "the button must fit the strip at \(height)")
            #expect(chrome.iconPointSize < chrome.button, "the icon must fit the button at \(height)")
            #expect(chrome.titlePointSize < chrome.height, "the title must fit the strip at \(height)")
            #expect(chrome.inset > 0, "the buttons must not touch the box edge at \(height)")
            #expect(chrome.height < height, "the header must never outgrow the box at \(height)")
        }
    }
}
