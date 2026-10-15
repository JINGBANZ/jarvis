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
        let box = OverlayBoxPanel()
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
        let box = OverlayBoxPanel()
        let window = try #require(NSApplication.shared.windows.first {
            !previous.contains(ObjectIdentifier($0))
        })
        defer { box.showAppearancePreview(false); box.setSessionLive(false) }
        box.showAppearancePreview(true)
        #expect(box.isPanelVisible)
        #expect(screen.frame.contains(window.frame))
        box.showAppearancePreview(false)
        box.setSessionLive(true)
        box.setContentSize(NSSize(width: 900, height: 900))
        _ = box.deliver("The test overlay belongs on the virtual display.", detail: nil)
        #expect(box.isPanelVisible)
        #expect(screen.frame.contains(window.frame))
        box.setSessionLive(false)
        #expect(!box.isPanelVisible)
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
