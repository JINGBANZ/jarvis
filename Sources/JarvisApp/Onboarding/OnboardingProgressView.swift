import AppKit

/// One dot per step shown this launch; hidden when there is only one.
@MainActor
final class OnboardingProgressView: NSView {
    private let current: Int
    private let count: Int

    init(step current: Int, of count: Int) {
        self.current = current
        self.count = count
        super.init(frame: .zero)
        isHidden = count < 2
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Step \(current) of \(count)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 20 + CGFloat(max(0, count - 1)) * 12, height: 6)
    }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        for step in 1...max(1, count) {
            let width: CGFloat = step == current ? 20 : 6
            (step <= current ? OnboardingTheme.teal : OnboardingTheme.line).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: x, y: (bounds.height - 6) / 2, width: width, height: 6),
                xRadius: 3, yRadius: 3).fill()
            x += width + 6
        }
    }
}
