import AppKit
import Testing
import JarvisCore
import JarvisTestDisplay
@testable import JarvisOverlay

typealias TestOverlayBox = (box: OverlayBoxPanel, close: @MainActor () -> Void)

@MainActor
func makeTestOverlayBox(contentSize: NSSize? = nil) -> TestOverlayBox {
    let previous = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
    let size = contentSize ?? NSSize(width: Defaults.Overlay.Box.width, height: Defaults.Overlay.Box.height)
    let box = OverlayBoxPanel(contentSize: size, makePanel: { rect, style in
        TestDisplayPanel(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
    })
    let windows = NSApplication.shared.windows.filter { !previous.contains(ObjectIdentifier($0)) }
    precondition(windows.count == 1, "An overlay fixture must own exactly one new window")
    let window = windows[0]
    window.isReleasedWhenClosed = false
    // These synchronous assertions do not drive an AppKit animation event loop.
    window.animationBehavior = .none
    return (box, {
        box.showAppearancePreview(false)
        box.setSessionLive(false)
        window.orderOut(nil)
        window.close()
        #expect(!window.isVisible, "The fixture must close its own overlay window")
    })
}
