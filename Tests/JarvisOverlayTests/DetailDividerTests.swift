import AppKit
import JarvisCore
import Testing
@testable import JarvisOverlay

@Suite struct DetailDividerTests {
    @MainActor @Test func draggingResizesWithoutMovingWindowAndSurvivesContentChanges() throws {
        let (box, window) = try makeBox()
        box.setEnabled(true)
        box.setSessionLive(true)
        defer { box.setSessionLive(false) }
        let detail = try #require(ReplyDetail(markdown: "```swift\nreturn 1\n```"))
        _ = box.deliver(["First hint"], perLineSeconds: [1], detail: detail)
        let divider = try divider(in: window)
        let frame = box.currentFrame
        let initial = box.currentDetailHeight
        try drag(divider, by: 70)
        #expect(abs(box.currentDetailHeight - initial - 70) < 0.01)
        #expect(box.currentFrame == frame)
        #expect(!divider.mouseDownCanMoveWindow)
        let chosen = box.currentDetailHeight
        _ = box.deliver(["New hint"], perLineSeconds: [1], detail: nil)
        #expect(box.currentDetailHeight == chosen)
        box.clickCollapseButton()
        #expect(divider.isHidden)
        box.clickCollapseButton()
        #expect(!divider.isHidden)
        #expect(abs(box.currentDetailHeight - chosen) < 0.01)
        box.setContentSize(NSSize(width: 503, height: 803))
        #expect(box.currentDetailHeight > chosen)
        box.setContentSize(NSSize(width: 503, height: 503))
        #expect(abs(box.currentDetailHeight - chosen) < 0.01)
        box.clear()
        #expect(divider.isHidden, "clearing the session's details takes the box away with them")
        #expect(box.currentDetailHeight == 0)
        _ = box.deliver(["Again"], perLineSeconds: [1], detail: detail)
        box.setSessionLive(false)
        box.setSessionLive(true)
        #expect(box.currentDetailHeight == 0, "a new session opens with no detail")
    }

    @MainActor @Test func dragLimitsKeepBothSectionsUsableAndAllowImmediateReversal() throws {
        let (box, window) = try makeBox()
        box.setEnabled(true)
        box.setSessionLive(true)
        defer { box.setSessionLive(false) }
        _ = box.deliver(["First hint"], perLineSeconds: [1],
                        detail: ReplyDetail(markdown: "```swift\nreturn 1\n```"))
        let divider = try divider(in: window)
        try drag(divider, by: -2000)
        #expect(box.currentDetailHeight >= 96)
        let smallest = box.currentDetailHeight
        try drag(divider, by: 20)
        #expect(abs(box.currentDetailHeight - smallest - 20) < 0.01)
        try drag(divider, by: 2000)
        #expect(box.currentDetailHeight < 503 - 44)
        let history = try #require(window.contentView?.subviews.compactMap { $0 as? NSScrollView }.first)
        #expect(history.frame.height >= 44)
        box.setContentSize(box.minimumContentSize)
        #expect(box.currentDetailHeight > 0)
        #expect(box.currentDetailHeight < box.currentContentSize.height - 44)
        #expect(history.frame.height >= 44)
    }

    @MainActor @Test func accessibilityActionsAdjustBothWaysWithinBoundsWithoutTakingFocus() throws {
        let (box, window) = try makeBox()
        box.setEnabled(true)
        box.setSessionLive(true)
        defer { box.setSessionLive(false) }
        _ = box.deliver(["First hint"], perLineSeconds: [1],
                        detail: ReplyDetail(markdown: "```swift\nreturn 1\n```"))
        let divider = try divider(in: window)
        let originalHeight = box.currentDetailHeight
        let originalFrame = box.currentFrame
        let keyWindow = NSApp.keyWindow
        let active = NSApp.isActive
        #expect(divider.accessibilityPerformIncrement())
        #expect(box.currentDetailHeight > originalHeight)
        #expect(divider.accessibilityPerformDecrement())
        #expect(abs(box.currentDetailHeight - originalHeight) < 0.01)
        try drag(divider, by: 2000)
        let maximum = box.currentDetailHeight
        #expect(!divider.accessibilityPerformIncrement())
        #expect(box.currentDetailHeight == maximum)
        #expect(divider.accessibilityPerformDecrement())
        #expect(box.currentDetailHeight < maximum)
        try drag(divider, by: -2000)
        let minimum = box.currentDetailHeight
        #expect(!divider.accessibilityPerformDecrement())
        #expect(box.currentDetailHeight == minimum)
        #expect(box.currentFrame == originalFrame)
        #expect(NSApp.keyWindow === keyWindow)
        #expect(NSApp.isActive == active)
        box.clickCollapseButton()
        #expect(!divider.accessibilityPerformIncrement())
        box.clickCollapseButton()
        #expect(abs(box.currentDetailHeight - minimum) < 0.01)
        box.setSessionLive(false)
        #expect(!divider.accessibilityPerformIncrement())
    }

    @MainActor private func makeBox() throws -> (OverlayBoxPanel, NSWindow) {
        let existing = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let box = OverlayBoxPanel(contentSize: NSSize(width: 503, height: 503))
        let window = try #require(NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) })
        return (box, window)
    }

    @MainActor private func divider(in window: NSWindow) throws -> NSView {
        return try #require(window.contentView?.subviews.first {
            $0.accessibilityLabel() == "Resize hints and detail"
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
