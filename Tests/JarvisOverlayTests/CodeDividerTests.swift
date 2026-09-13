import AppKit
import JarvisCore
import Testing
@testable import JarvisOverlay

@Suite struct CodeDividerTests {
    @MainActor @Test func draggingResizesWithoutMovingWindowAndSurvivesContentChanges() throws {
        let (box, window) = try makeBox()
        box.setCodeEnabled(true)
        box.setEnabled(true)
        box.setSessionLive(true)
        defer { box.setSessionLive(false) }
        let divider = try divider(in: window)
        let frame = box.currentFrame
        let initial = box.currentCodeHeight
        try drag(divider, by: 70)
        #expect(abs(box.currentCodeHeight - initial - 70) < 0.01)
        #expect(box.currentFrame == frame)
        #expect(!divider.mouseDownCanMoveWindow)
        let chosen = box.currentCodeHeight
        let snippet = try #require(CodeSnippet(language: "swift", placement: "Start", code: "return 1"))
        _ = box.deliverCodeSnippet(snippet)
        _ = box.deliver(["New hint"], perLineSeconds: [1], diagram: nil, explanation: nil)
        #expect(box.currentCodeHeight == chosen)
        box.clickCollapseButton()
        #expect(divider.isHidden)
        box.clickCollapseButton()
        #expect(!divider.isHidden)
        #expect(abs(box.currentCodeHeight - chosen) < 0.01)
        box.setContentSize(NSSize(width: 503, height: 803))
        #expect(box.currentCodeHeight > chosen)
        box.setContentSize(NSSize(width: 503, height: 503))
        #expect(abs(box.currentCodeHeight - chosen) < 0.01)
        box.clear()
        #expect(abs(box.currentCodeHeight - chosen) < 0.01)
        box.setCodeEnabled(false)
        #expect(divider.isHidden)
        #expect(box.currentCodeHeight == 0)
        box.setCodeEnabled(true)
        box.setSessionLive(false)
        box.setSessionLive(true)
        #expect(box.currentCodeHeight == initial)
    }

    @MainActor @Test func dragLimitsKeepBothSectionsUsableAndAllowImmediateReversal() throws {
        let (box, window) = try makeBox()
        box.setCodeEnabled(true)
        let divider = try divider(in: window)
        try drag(divider, by: -2000)
        #expect(box.currentCodeHeight >= 96)
        let smallest = box.currentCodeHeight
        try drag(divider, by: 20)
        #expect(abs(box.currentCodeHeight - smallest - 20) < 0.01)
        try drag(divider, by: 2000)
        #expect(box.currentCodeHeight < 503 - 44)
        let history = try #require(window.contentView?.subviews.compactMap { $0 as? NSScrollView }.first)
        #expect(history.frame.height >= 44)
        box.setContentSize(box.minimumContentSize)
        #expect(box.currentCodeHeight > 0)
        #expect(box.currentCodeHeight < box.currentContentSize.height - 44)
        #expect(history.frame.height >= 44)
    }

    @MainActor private func makeBox() throws -> (OverlayBoxPanel, NSWindow) {
        let existing = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let box = OverlayBoxPanel(contentSize: NSSize(width: 503, height: 503))
        let window = try #require(NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) })
        return (box, window)
    }

    @MainActor private func divider(in window: NSWindow) throws -> NSView {
        return try #require(window.contentView?.subviews.first {
            $0.accessibilityLabel() == "Resize code and hints"
        })
    }

    @MainActor private func drag(_ view: NSView, by delta: CGFloat) throws {
        let window = try #require(view.window)
        let start = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        #expect(window.contentView?.hitTest(start) === view)
        for (type, y) in [(NSEvent.EventType.leftMouseDown, start.y),
                          (.leftMouseDragged, start.y + delta), (.leftMouseUp, start.y + delta)] {
            let event = try #require(NSEvent.mouseEvent(with: type,
                location: NSPoint(x: start.x, y: y), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
        }
    }
}
