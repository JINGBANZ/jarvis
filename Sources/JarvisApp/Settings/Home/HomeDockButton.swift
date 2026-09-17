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
    private let litSymbol: NSImage?
    private let label: NSAttributedString

    override var isFlipped: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }

    init(destination: SettingsDestination, title: String, symbolName: String) {
        self.destination = destination
        let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        let size = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        symbol = base?.withSymbolConfiguration(
            size.applying(NSImage.SymbolConfiguration(paletteColors: [SettingsTheme.purple])))
        litSymbol = base?.withSymbolConfiguration(
            size.applying(NSImage.SymbolConfiguration(paletteColors: [SettingsTheme.teal])))
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

    /// Inset a point so the 2-point hover stroke stays inside the bounds.
    private func chamferPath() -> NSBezierPath {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let (x0, y0, x1, y1) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x0 + 16, y: y0))
        path.line(to: NSPoint(x: x1 - 16, y: y0))
        path.line(to: NSPoint(x: x1, y: y0 + 16))
        path.line(to: NSPoint(x: x1, y: y1))
        path.line(to: NSPoint(x: x0 + 16, y: y1))
        path.line(to: NSPoint(x: x0, y: y1 - 16))
        path.line(to: NSPoint(x: x0, y: y0))
        path.close()
        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = chamferPath()
        let lit = isHovered || window?.firstResponder === self
        let fill = isHighlighted
            ? (SettingsTheme.cardFill.blended(withFraction: 0.1, of: .black) ?? SettingsTheme.cardFill)
            : SettingsTheme.cardFill
        fill.setFill()
        path.fill()
        if lit {
            SettingsTheme.highlightFill.setFill()
            path.fill()
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = SettingsTheme.slotGlow
            glow.shadowBlurRadius = 8
            glow.shadowOffset = .zero
            glow.set()
            SettingsTheme.teal.setStroke()
            path.lineWidth = 2
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            SettingsTheme.purple.withAlphaComponent(0.5).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        let gap: CGFloat = 6
        let icon = lit ? litSymbol : symbol
        let symbolSize = icon?.size ?? .zero
        let labelSize = label.size()
        var top = floor((bounds.height - symbolSize.height - gap - labelSize.height) / 2)
        icon?.draw(
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
