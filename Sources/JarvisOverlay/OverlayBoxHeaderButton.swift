import AppKit

/// AppKit has no borderless button style that highlights on hover, so a tracking area draws it.
final class OverlayBoxHeaderButton: NSButton {
    private static let idleTint = NSColor(white: 1, alpha: 0.55)
    private static let hoverTint = NSColor(white: 1, alpha: 1)
    private static let hoverFill = NSColor(white: 1, alpha: 0.14).cgColor

    private var symbolName: String
    /// Never a `toolTip`: AppKit draws one in its own window, outside the box's capture exclusion.
    private var label: String = ""
    private var iconPointSize: CGFloat = 16
    private var hoverTracking: NSTrackingArea?

    init(symbol: String, label: String) {
        symbolName = symbol
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        title = ""
        wantsLayer = true
        contentTintColor = Self.idleTint
        setSymbol(symbol, label: label)
    }

    required init?(coder: NSCoder) { fatalError("built in code; this project has no nibs") }

    func setSymbol(_ name: String, label: String) {
        symbolName = name
        self.label = label
        setAccessibilityLabel(label)
        refreshImage()
    }

    func apply(iconPointSize: CGFloat, cornerRadius: CGFloat) {
        self.iconPointSize = iconPointSize
        layer?.cornerRadius = cornerRadius
        refreshImage()
    }

    private func refreshImage() {
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: iconPointSize, weight: .medium))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = Self.hoverFill
        contentTintColor = Self.hoverTint
    }

    override func mouseExited(with event: NSEvent) { clearHover() }

    /// AppKit sends no `mouseExited` to a view hidden under the pointer, so clear the hover here.
    override func viewDidHide() {
        super.viewDidHide()
        clearHover()
    }

    private func clearHover() {
        layer?.backgroundColor = nil
        contentTintColor = Self.idleTint
    }
}

