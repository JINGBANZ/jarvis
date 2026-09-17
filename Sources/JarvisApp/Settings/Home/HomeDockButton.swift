import AppKit

/// Draws its own symbol and title: the cell's image-above layout pins the symbol to the top edge
/// of a tall button.
@MainActor
final class HomeDockButton: NSButton {
    let destination: SettingsDestination
    var onOpen: ((SettingsDestination, NSPoint) -> Void)?

    private var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }
    private var trackingArea: NSTrackingArea?
    private let symbol: NSImage?
    private let label: NSAttributedString

    override var isFlipped: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }

    init(destination: SettingsDestination, title: String, symbolName: String) {
        self.destination = destination
        symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [SettingsTheme.purple])))
        label = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: SettingsTheme.text,
        ])
        super.init(frame: NSRect(x: 0, y: 0, width: 138, height: 84))
        isBordered = false
        self.title = ""
        imagePosition = .noImage
        setAccessibilityLabel(title)
        target = self
        action = #selector(open)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Inset half a point so the stroke stays inside the bounds.
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

        let gap: CGFloat = 6
        let symbolSize = symbol?.size ?? .zero
        let labelSize = label.size()
        var top = floor((bounds.height - symbolSize.height - gap - labelSize.height) / 2)
        symbol?.draw(
            in: NSRect(x: floor((bounds.width - symbolSize.width) / 2), y: top,
                       width: symbolSize.width, height: symbolSize.height),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        top += symbolSize.height + gap
        label.draw(at: NSPoint(x: floor((bounds.width - labelSize.width) / 2), y: top))
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
