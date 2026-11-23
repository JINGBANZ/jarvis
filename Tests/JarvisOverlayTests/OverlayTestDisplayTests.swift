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
        #expect(box.isPanelVisible)
        let beforeResize = try await expectWindowServerPlacement(window)
        let size = NSSize(width: 900, height: 900)
        box.setContentSize(size)
        _ = box.deliver("The test overlay belongs on the virtual display.", detail: nil)
        #expect(box.isPanelVisible)
        #expect(window.frame.size == size)
        #expect(screen.frame.contains(window.frame))
        try await expectWindowServerPlacement(window, largerThan: beforeResize.size)
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
        #expect(box.isPanelVisible)
        let beforeMove = try await expectWindowServerPlacement(window)
        // Resize during the move so the previous WindowServer frame cannot satisfy the check.
        let size = NSSize(width: 900, height: 900)
        window.setFrame(NSRect(origin: outside, size: size), display: true)
        #expect(window.frame.size == size)
        #expect(screen.visibleFrame.contains(window.frame))
        try await expectWindowServerPlacement(window, largerThan: beforeMove.size)
    }

    @MainActor
    @discardableResult
    private func expectWindowServerPlacement(_ window: NSWindow, largerThan previousSize: CGSize? = nil) async throws -> CGRect {
        let raw = try #require(ProcessInfo.processInfo.environment["JARVIS_TEST_DISPLAY_ID"])
        let id = try #require(CGDirectDisplayID(raw))
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        var committed: CGRect?
        // WindowServer can report transformed bounds while the session is locked.
        repeat {
            let rows = try #require(CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]])
            if let row = rows.first(where: {
                ($0[kCGWindowNumber as String] as? Int) == window.windowNumber
                    && ($0[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier
            }) {
                let bounds = try #require(row[kCGWindowBounds as String] as? [String: Any])
                let frame = try #require(CGRect(dictionaryRepresentation: bounds as CFDictionary))
                if !frame.isEmpty {
                    try #require(CGDisplayBounds(id).contains(frame),
                                 "WindowServer must keep every observed window frame on the test display")
                    if frame.width > (previousSize?.width ?? 0), frame.height > (previousSize?.height ?? 0) {
                        committed = frame
                        break
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        return try #require(committed, "WindowServer must publish the test window frame after the change")
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
