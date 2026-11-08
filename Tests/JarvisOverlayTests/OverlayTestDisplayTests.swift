import AppKit
import Testing
@testable import JarvisOverlay

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["JARVIS_TEST_DISPLAY_ID"] != nil,
                            "requires the local runner's isolated test display"))
struct OverlayTestDisplayTests {
    @MainActor @Test
    func positionsThePanelBeforeItCanAppear() throws {
        let screen = try testScreen()
        let previous = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let (box, closeBox) = makeTestOverlayBox()
        defer { closeBox() }
        let window = try #require(NSApplication.shared.windows.first {
            !previous.contains(ObjectIdentifier($0))
        })
        #expect(!box.isPanelVisible)
        #expect(screen.frame.contains(window.frame))
        #expect(NSScreen.screens.filter { $0 != screen }.allSatisfy { !$0.frame.intersects(window.frame) })
    }

    @MainActor @Test
    func sessionPreviewAndResizeStayOnTheTestDisplay() throws {
        let screen = try testScreen()
        let previous = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let (box, closeBox) = makeTestOverlayBox()
        defer { closeBox() }
        let window = try #require(NSApplication.shared.windows.first {
            !previous.contains(ObjectIdentifier($0))
        })
        defer { box.showAppearancePreview(false); box.setSessionLive(false) }
        box.showAppearancePreview(true)
        #expect(box.isPanelVisible)
        #expect(screen.frame.contains(window.frame))
        try expectWindowServerPlacement(window)
        box.showAppearancePreview(false)
        box.setSessionLive(true)
        box.setContentSize(NSSize(width: 900, height: 900))
        _ = box.deliver("The test overlay belongs on the virtual display.", detail: nil)
        #expect(box.isPanelVisible)
        #expect(screen.frame.contains(window.frame))
        try expectWindowServerPlacement(window)
        box.setSessionLive(false)
        #expect(!box.isPanelVisible)
    }

    @MainActor @Test
    func proposedDesktopMovesStayOnTheIsolatedDisplay() throws {
        let screen = try testScreen()
        let previous = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let (box, closeBox) = makeTestOverlayBox()
        defer { closeBox() }
        let window = try #require(NSApplication.shared.windows.first {
            !previous.contains(ObjectIdentifier($0))
        })
        let outside = NSPoint(x: screen.frame.minX - window.frame.width - 100,
                              y: screen.frame.minY - window.frame.height - 100)
        window.setFrameOrigin(outside)
        #expect(screen.visibleFrame.contains(window.frame))
        box.setSessionLive(true)
        window.setFrame(NSRect(origin: outside, size: window.frame.size), display: true)
        #expect(screen.visibleFrame.contains(window.frame))
        try expectWindowServerPlacement(window)
    }

    @MainActor
    private func expectWindowServerPlacement(_ window: NSWindow) throws {
        let raw = try #require(ProcessInfo.processInfo.environment["JARVIS_TEST_DISPLAY_ID"])
        let id = try #require(CGDirectDisplayID(raw))
        let rows = try #require(CGWindowListCopyWindowInfo(.optionIncludingWindow,
                                  CGWindowID(window.windowNumber)) as? [[String: Any]])
        let row = try #require(rows.first { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber })
        let bounds = try #require(row[kCGWindowBounds as String] as? [String: Any])
        let frame = try #require(CGRect(dictionaryRepresentation: bounds as CFDictionary))
        #expect(CGDisplayBounds(id).contains(frame), "WindowServer must place the actual window on the test display")
    }

    @MainActor
    private func testScreen() throws -> NSScreen {
        let raw = try #require(ProcessInfo.processInfo.environment["JARVIS_TEST_DISPLAY_ID"])
        let id = try #require(CGDirectDisplayID(raw))
        return try #require(NSScreen.screens.first {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == id
        })
    }
}
