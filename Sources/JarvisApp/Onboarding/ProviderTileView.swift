import AppKit
import JarvisCore

/// One vendor a first key can come from, naming the brain and ear that key would set.
@MainActor
final class ProviderTileView: NSButton {
    static let height: CGFloat = 110

    let credential: Credential
    var isChosen = false {
        didSet {
            guard oldValue != isChosen else { return }
            setAccessibilityValue(NSNumber(value: isChosen))
            needsDisplay = true
        }
    }

    private let lines: [(symbol: String, text: String)]
    private let onChoose: (Credential) -> Void

    init(
        credential: Credential, thinks: String, listens: String,
        onChoose: @escaping (Credential) -> Void
    ) {
        self.credential = credential
        self.lines = [("brain", "Thinks with \(thinks)"), ("ear", "Listens with \(listens)")]
        self.onChoose = onChoose
        super.init(frame: NSRect(x: 0, y: 0, width: 284, height: Self.height))
        isBordered = false
        title = ""
        imagePosition = .noImage
        target = self
        action = #selector(choose)
        toolTip = lines.map(\.text).joined(separator: "\n")
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(([credential.vendorName] + lines.map(\.text)).joined(separator: ". "))
        setAccessibilityValue(NSNumber(value: false))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    /// Inset so the chosen ring stays inside the bounds.
    private var card: NSRect { bounds.insetBy(dx: 3, dy: 3) }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12)
        if isChosen {
            let ring = NSBezierPath(
                roundedRect: card.insetBy(dx: -1.5, dy: -1.5), xRadius: 13.5, yRadius: 13.5)
            ring.lineWidth = 3
            OnboardingTheme.ring.setStroke()
            ring.stroke()
        }
        OnboardingTheme.card.setFill()
        shape.fill()
        shape.lineWidth = isChosen ? 1.5 : 1
        (isChosen ? OnboardingTheme.teal : OnboardingTheme.line).setStroke()
        shape.stroke()

        let well = NSRect(x: card.minX + 14, y: card.minY + 14, width: 30, height: 30)
        OnboardingTheme.well.setFill()
        NSBezierPath(roundedRect: well, xRadius: 8, yRadius: 8).fill()
        drawSymbol("key", centeredIn: well, pointSize: 15,
                   color: isChosen ? OnboardingTheme.teal : OnboardingTheme.purple)

        let name = NSAttributedString(string: credential.vendorName, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: OnboardingTheme.text,
        ])
        name.draw(at: NSPoint(x: well.maxX + 10, y: well.midY - name.size().height / 2))
        if isChosen {
            let tag = NSAttributedString(string: "SELECTED", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 9.5), .kern: 1.6,
                .foregroundColor: OnboardingTheme.tealText,
            ])
            tag.draw(at: NSPoint(x: card.maxX - 14 - tag.size().width,
                                 y: well.midY - tag.size().height / 2))
        }

        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        for (index, line) in lines.enumerated() {
            let top = well.maxY + 10 + CGFloat(index) * 19
            drawSymbol(line.symbol, centeredIn: NSRect(x: card.minX + 14, y: top, width: 14, height: 16),
                       pointSize: 12, color: OnboardingTheme.tertiaryText)
            let text = NSAttributedString(string: line.text, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: OnboardingTheme.secondaryText,
                .paragraphStyle: truncating,
            ])
            text.draw(with: NSRect(x: card.minX + 34, y: top, width: card.maxX - 14 - (card.minX + 34), height: 16),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12).fill()
    }

    override var focusRingMaskBounds: NSRect { card }

    @objc private func choose() {
        onChoose(credential)
    }

    private func drawSymbol(_ name: String, centeredIn rect: NSRect, pointSize: CGFloat, color: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = image.size
        image.draw(
            in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                       width: size.width, height: size.height),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
