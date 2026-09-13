import AppKit

/// A narrow drag target keeps window movement available everywhere outside the divider.
@MainActor
final class OverlayCodeDividerView: NSView {
    static let thickness: CGFloat = 8
    var onHeightChanged: ((CGFloat) -> Void)?
    private var dragStart: (pointerY: CGFloat, height: CGFloat)?
    private var isHovered = false
    private var hoverTracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Resize code and hints")
    }

    required init?(coder: NSCoder) { fatalError("built in code; this project has no nibs") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        guard !isHidden else { return }
        dragStart = (event.locationInWindow.y, frame.midY)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isHidden, let dragStart else { return }
        // Window coordinates remain stable while this view moves with the divider.
        onHeightChanged?(dragStart.height + event.locationInWindow.y - dragStart.pointerY)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        isHovered = bounds.contains(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = isHovered || dragStart != nil
        // Like the outer resize grips, draw feedback inside the excluded panel: inactive apps
        // cannot reliably set a resize cursor, and a tooltip would create another window.
        NSColor(white: 1, alpha: highlighted ? 0.7 : 0.25).setFill()
        NSRect(x: 0, y: bounds.midY, width: bounds.width, height: 1).fill()
        let grip = NSRect(x: bounds.midX - 18, y: bounds.midY - 1, width: 36, height: 3)
        NSBezierPath(roundedRect: grip, xRadius: 1.5, yRadius: 1.5).fill()
    }
}
