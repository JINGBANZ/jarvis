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
    func sessionPreviewAndResizeStayOnTheTestDisplay() async throws {
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
        try await expectWindowServerPlacement(window)
        box.showAppearancePreview(false)
        box.setSessionLive(true)
        box.setContentSize(NSSize(width: 900, height: 900))
        _ = box.deliver("The test overlay belongs on the virtual display.", detail: nil)
        #expect(box.isPanelVisible)
        #expect(screen.frame.contains(window.frame))
        try await expectWindowServerPlacement(window)
        box.setSessionLive(false)
        #expect(!box.isPanelVisible)
    }

    @MainActor @Test
    func proposedDesktopMovesStayOnTheIsolatedDisplay() async throws {
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
        try await expectWindowServerPlacement(window)
    }

    @MainActor
    private func expectWindowServerPlacement(_ window: NSWindow) async throws {
        let raw = try #require(ProcessInfo.processInfo.environment["JARVIS_TEST_DISPLAY_ID"])
        let id = try #require(CGDirectDisplayID(raw))
        let primary = try #require(NSScreen.screens.first {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == CGMainDisplayID()
        })
        let expected = CGRect(x: window.frame.minX, y: primary.frame.maxY - window.frame.maxY,
                              width: window.frame.width, height: window.frame.height)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        var committed: CGRect?
        // AppKit publishes ordering and bounds when the main run loop commits each change.
        repeat {
            let rows = try #require(CGWindowListCopyWindowInfo(.optionIncludingWindow,
                                      CGWindowID(window.windowNumber)) as? [[String: Any]])
            if let row = rows.first(where: {
                ($0[kCGWindowNumber as String] as? Int) == window.windowNumber
                    && ($0[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier
                    && ($0[kCGWindowIsOnscreen as String] as? Bool) == true
            }) {
                let bounds = try #require(row[kCGWindowBounds as String] as? [String: Any])
                let frame = try #require(CGRect(dictionaryRepresentation: bounds as CFDictionary))
                try #require(frame.width > 0 && frame.height > 0)
                try #require(CGDisplayBounds(id).contains(frame),
                             "WindowServer must keep every observed window frame on the test display")
                if frame == expected {
                    committed = frame
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        _ = try #require(committed, "WindowServer must publish the current visible test window frame")
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
