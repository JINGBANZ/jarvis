import AppKit
import JarvisTestHost
import Testing
@testable import JarvisOverlay

typealias TestOverlayBox = (box: OverlayBoxPanel, close: @MainActor () -> Void)

@MainActor
func makeTestOverlayBox(contentSize: NSSize? = nil) -> TestOverlayBox {
    jarvis_test_host_link()
    let previous = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
    let box = contentSize.map { OverlayBoxPanel(contentSize: $0) } ?? OverlayBoxPanel()
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
