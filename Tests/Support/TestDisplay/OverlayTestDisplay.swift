#if DEBUG
import AppKit

@MainActor
public final class OverlayTestDisplay: NSObject {
    private let displayID: CGDirectDisplayID
    private weak var window: NSWindow?
    private var isPositioning = false

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
        for name in [NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(placementChanged), name: name, object: window)
        }
        position()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    public static var requestedScreen: NSScreen? {
        guard let raw = ProcessInfo.processInfo.environment["JARVIS_TEST_DISPLAY_ID"] else { return nil }
        guard let id = CGDirectDisplayID(raw), let screen = resolve(id) else {
            fail("The isolated test display is unavailable; refusing to use the desktop.")
        }
        return screen
    }

    func position() {
        guard !isPositioning, let window else { return }
        isPositioning = true
        defer { isPositioning = false }
        guard let screen = Self.resolve(displayID) else {
            window.orderOut(nil)
            Self.fail("The isolated test display disappeared; stopping before showing an overlay on the desktop.")
        }
        guard let frame = TestWindowPlacement.frame(window.frame, within: screen.visibleFrame) else {
            window.orderOut(nil)
            Self.fail("The test window does not fit on the isolated display.")
        }
        if frame != window.frame {
            window.setFrameOrigin(frame.origin)
        }
        guard screen.visibleFrame.contains(window.frame) else {
            window.orderOut(nil)
            Self.fail("AppKit did not place the test window on its isolated display.")
        }
    }

    static func constrainedFrame(_ proposed: NSRect) -> NSRect? {
        guard let screen = requestedScreen else { return nil }
        guard let frame = TestWindowPlacement.frame(proposed, within: screen.visibleFrame) else {
            fail("The proposed test window frame does not fit on the isolated display.")
        }
        return frame
    }

    func verifyVisiblePlacement() {
        guard let window, window.isVisible else { return }
        guard let screen = Self.resolve(displayID),
              screen.visibleFrame.contains(window.frame), window.screen == screen else {
            window.orderOut(nil)
            Self.fail("A visible test window left its isolated display.")
        }
    }

    @objc private func placementChanged() {
        guard !isPositioning else { return }
        if window?.isVisible == true { verifyVisiblePlacement() } else { position() }
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
#endif
