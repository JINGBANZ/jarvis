import AppKit
import JarvisCore

/// One hub slot: a part's icon, name, current line, and status light. It is a keyboard-focusable
/// button; hovering or focusing it lights the matching part of the head.
@MainActor
final class RobotSlotView: NSView {
    let part: RobotPart
    var onClick: ((NSPoint) -> Void)?
    var onHighlight: ((Bool) -> Void)?
    var isHighlighted = false {
        didSet { if oldValue != isHighlighted { needsDisplay = true } }
    }

    private let statusLight = CALayer()
    private let iconWell = CALayer()
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let bars = [CALayer(), CALayer(), CALayer()]
    private var slot: RobotSlotState?
    private var isPressed = false {
        didSet { needsDisplay = true }
    }
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }

    init(part: RobotPart) {
        self.part = part
        super.init(frame: NSRect(x: 0, y: 0, width: 232, height: 76))
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1.4
        layer?.shadowOffset = .zero
        layer?.shadowRadius = 6
        iconWell.cornerRadius = 10
        layer?.addSublayer(iconWell)
        bars.forEach {
            $0.cornerRadius = 1.5
            $0.borderWidth = 1
            layer?.addSublayer($0)
        }
        statusLight.cornerRadius = 3.5
        layer?.addSublayer(statusLight)

        icon.image = NSImage(systemSymbolName: part.symbolName, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        icon.contentTintColor = part == .brain ? SettingsTheme.teal : SettingsTheme.purple
        nameLabel.attributedStringValue = NSAttributedString(string: part.title.uppercased(), attributes: [
            .kern: 2, .font: NSFont.boldSystemFont(ofSize: 10.5), .foregroundColor: SettingsTheme.purple,
        ])
        valueLabel.font = .systemFont(ofSize: 13)
        valueLabel.textColor = SettingsTheme.text
        valueLabel.lineBreakMode = .byTruncatingTail
        detailLabel.lineBreakMode = .byTruncatingTail
        [icon, nameLabel, valueLabel, detailLabel].forEach(addSubview)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(part.title) settings")
        focusRingType = .default
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(_ state: RobotSlotState) {
        slot = state
        valueLabel.stringValue = state.value
        let color = switch state.tone {
        case .normal: SettingsTheme.mutedText
        case .live: SettingsTheme.teal
        case .attention: SettingsTheme.amber
        }
        // Theme colors are dynamic, so the attributed string follows appearance changes when it draws.
        detailLabel.attributedStringValue = NSAttributedString(string: state.detail, attributes: [
            .kern: 1.5, .font: NSFont.systemFont(ofSize: 9.5), .foregroundColor: color,
        ])
        setAccessibilityValue("\(state.value), \(state.detail.lowercased())")
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconWell.frame = CGRect(x: 12, y: 14, width: 46, height: 46)
        icon.frame = NSRect(x: 12, y: 14, width: 46, height: 46)
        nameLabel.frame = NSRect(x: 70, y: 12, width: 90, height: 14)
        valueLabel.frame = NSRect(x: 70, y: 29, width: bounds.width - 82, height: 18)
        detailLabel.frame = NSRect(x: 70, y: 52, width: bounds.width - 82, height: 13)
        let barsRight = bounds.width - 26
        for (index, bar) in bars.enumerated() {
            bar.frame = CGRect(x: barsRight - CGFloat(3 - index) * 17 + 3, y: 16, width: 14, height: 6)
        }
        statusLight.frame = CGRect(x: bounds.width - 17.5, y: 10.5, width: 7, height: 7)
        CATransaction.commit()
    }

    override func updateLayer() {
        guard let layer else { return }
        let lit = isHighlighted || window?.firstResponder === self
        let fill = isPressed
            ? (SettingsTheme.cardFill.blended(withFraction: 0.1, of: .black) ?? SettingsTheme.cardFill)
            : SettingsTheme.cardFill
        layer.backgroundColor = fill.cgColor
        let border = slot?.tone == .attention ? SettingsTheme.amber
            : lit ? SettingsTheme.teal : SettingsTheme.purple.withAlphaComponent(0.55)
        layer.borderColor = border.cgColor
        layer.shadowColor = SettingsTheme.slotGlow.cgColor
        layer.shadowOpacity = lit ? 1 : 0
        iconWell.backgroundColor = SettingsTheme.iconWell.cgColor
        let level = slot?.level
        for (index, bar) in bars.enumerated() {
            bar.isHidden = level == nil
            let isLit = index < (level ?? 0)
            bar.backgroundColor = isLit ? SettingsTheme.teal.cgColor : NSColor.clear.cgColor
            bar.borderColor = isLit ? SettingsTheme.teal.cgColor : SettingsTheme.dimText.cgColor
        }
        let health = slot?.health
        statusLight.isHidden = health == nil
        statusLight.backgroundColor = (health?.isReady == false ? SettingsTheme.amber : SettingsTheme.teal).cgColor
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
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
        isHighlighted = false
        isPressed = false
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
        onHighlight?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
        onHighlight?(false)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?(event.locationInWindow)
        }
    }

    override func keyDown(with event: NSEvent) {
        // Space, Return, or keypad Enter.
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 || event.keyCode == 76 {
            press()
        } else {
            super.keyDown(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        onHighlight?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        onHighlight?(false)
        return true
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }

    private func press() {
        onClick?(convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil))
    }
}
