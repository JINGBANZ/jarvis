import AppKit

@MainActor
final class OverlayTestDisplay: NSObject {
    private let displayID: CGDirectDisplayID
    private weak var window: NSWindow?

    init?(window: NSWindow) {
        guard let raw = ProcessInfo.processInfo.environment["JARVIS_TEST_DISPLAY_ID"] else { return nil }
        guard let id = CGDirectDisplayID(raw) else { Self.fail("Invalid test display ID.") }
        displayID = id
        self.window = window
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSWindow.didResizeNotification, object: window)
        position()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    static var requestedScreen: NSScreen? {
        guard let raw = ProcessInfo.processInfo.environment["JARVIS_TEST_DISPLAY_ID"] else { return nil }
        guard let id = CGDirectDisplayID(raw), let screen = resolve(id) else {
            fail("The isolated test display is unavailable; refusing to use the desktop.")
        }
        return screen
    }

    func position() {
        guard let window else { return }
        guard let screen = Self.resolve(displayID) else {
            window.orderOut(nil)
            Self.fail("The isolated test display disappeared; stopping before showing an overlay on the desktop.")
        }
        let frame = screen.visibleFrame
        guard window.frame.width <= frame.width, window.frame.height <= frame.height else {
            window.orderOut(nil)
            Self.fail("The test window does not fit on the isolated display.")
        }
        if !frame.contains(window.frame) {
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2,
                                          y: frame.midY - window.frame.height / 2))
        }
        guard frame.contains(window.frame) else {
            window.orderOut(nil)
            Self.fail("AppKit did not place the test window on its isolated display.")
        }
    }

    @objc private func screenChanged() { position() }

    private static func resolve(_ id: CGDirectDisplayID) -> NSScreen? {
        guard CGDisplayIsOnline(id) != 0,
              CGDisplayVendorNumber(id) == 0x4A56,
              CGDisplayModelNumber(id) == 0x5453,
              CGDisplayIsInMirrorSet(id) == 0,
              let screen = NSScreen.screens.first(where: {
                  $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == id
              }),
              NSScreen.screens.filter({ $0 != screen }).allSatisfy({ !$0.frame.intersects(screen.frame) })
        else { return nil }
        return screen
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("Test display: " + message + "\n").utf8))
        exit(1)
    }
}
