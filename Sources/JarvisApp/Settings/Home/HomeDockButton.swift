import AppKit

/// One of the hub's bottom buttons: a chamfered tile with a symbol above its title. It draws its
/// frame in `draw(_:)` before the cell draws the symbol and title, because a sublayer would cover
/// the button's own content.
@MainActor
final class HomeDockButton: NSButton {
    let destination: SettingsDestination
    var onOpen: ((SettingsDestination, NSPoint) -> Void)?

    private var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }

    init(destination: SettingsDestination, title: String, symbolName: String) {
        self.destination = destination
        super.init(frame: NSRect(x: 0, y: 0, width: 138, height: 84))
        isBordered = false
        imagePosition = .imageAbove
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
        contentTintColor = SettingsTheme.purple
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: SettingsTheme.text,
        ])
        setAccessibilityLabel(title)
        target = self
        action = #selector(open)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The contract's outline, inset half a point so the stroke stays inside the bounds.
    private func chamferPath() -> NSBezierPath {
        let w = bounds.width - 1
        let h = bounds.height - 1
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 16.5, y: 0.5))
        path.line(to: NSPoint(x: w - 15.5, y: 0.5))
        path.line(to: NSPoint(x: w + 0.5, y: 16.5))
        path.line(to: NSPoint(x: w + 0.5, y: h + 0.5))
        path.line(to: NSPoint(x: 16.5, y: h + 0.5))
        path.line(to: NSPoint(x: 0.5, y: h - 15.5))
        path.line(to: NSPoint(x: 0.5, y: 0.5))
        path.close()
        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = chamferPath()
        let fill = isHighlighted
            ? (SettingsTheme.cardFill.blended(withFraction: 0.1, of: .black) ?? SettingsTheme.cardFill)
            : SettingsTheme.cardFill
        fill.setFill()
        path.fill()
        let lit = isHovered || window?.firstResponder === self
        (lit ? SettingsTheme.teal : SettingsTheme.purple.withAlphaComponent(0.5)).setStroke()
        path.lineWidth = 1
        path.stroke()
        super.draw(dirtyRect)
    }

    override func drawFocusRingMask() {
        chamferPath().fill()
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // No mouseExited arrives when the hub leaves the window.
        isHovered = false
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    @objc private func open() {
        onOpen?(destination, convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil))
    }
}
