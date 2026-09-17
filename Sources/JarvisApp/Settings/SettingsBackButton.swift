import AppKit

@MainActor
final class SettingsBackButton: NSButton {
    private var isHovered = false {
        didSet { if oldValue != isHovered { applyColors() } }
    }
    private var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 84, height: 28))
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        keyEquivalent = "["
        keyEquivalentModifierMask = [.command]
        setAccessibilityLabel("Back to Jarvis")
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
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
        isHovered = false
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func applyColors() {
        let tint = isHovered ? SettingsTheme.teal : SettingsTheme.mutedText
        attributedTitle = NSAttributedString(string: "‹ JARVIS", attributes: [
            .kern: 2, .font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: tint,
        ])
        layer?.borderColor = themedCGColor(isHovered ? SettingsTheme.teal : SettingsTheme.line)
        layer?.backgroundColor = themedCGColor(SettingsTheme.fieldFill)
    }
}
