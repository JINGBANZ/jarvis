import AppKit

@MainActor
final class ShortcutKeycapsView: NSView {
    private static let capHeight: CGFloat = 26
    private static let minimumCapWidth: CGFloat = 26
    private static let gap: CGFloat = 4
    private static let font = NSFont.systemFont(ofSize: 13)

    var keys: [String] = [] {
        didSet {
            guard keys != oldValue else { return }
            setAccessibilityValue(keys.joined())
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let widths = keys.map(capWidth)
        let total = widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * Self.gap
        return NSSize(width: total, height: Self.capHeight)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func label(_ key: String) -> NSAttributedString {
        NSAttributedString(string: key, attributes: [
            .font: Self.font, .foregroundColor: SettingsTheme.text,
        ])
    }

    private func capWidth(_ key: String) -> CGFloat {
        max(Self.minimumCapWidth, ceil(label(key).size().width) + 12)
    }

    override func draw(_ dirtyRect: NSRect) {
        var x = bounds.width - intrinsicContentSize.width
        let top = floor((bounds.height - Self.capHeight) / 2)
        for key in keys {
            let width = capWidth(key)
            let cap = NSRect(x: x, y: top, width: width, height: Self.capHeight)
            // The thicker bottom edge is the outline showing below an inset face.
            SettingsTheme.purple.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: cap, xRadius: 6, yRadius: 6).fill()
            let face = NSRect(x: cap.minX + 1, y: cap.minY + 1, width: cap.width - 2, height: cap.height - 4)
            SettingsTheme.fieldFill.setFill()
            NSBezierPath(roundedRect: face, xRadius: 5, yRadius: 5).fill()

            let text = label(key)
            let size = text.size()
            // Center the capitals: glyphs such as ⌘ and J sit on the baseline with no descender.
            let baseline = face.midY + Self.font.capHeight / 2
            text.draw(at: NSPoint(
                x: pixelAligned(face.midX - size.width / 2),
                y: pixelAligned(baseline - Self.font.ascender)))
            x += width + Self.gap
        }
    }
}
