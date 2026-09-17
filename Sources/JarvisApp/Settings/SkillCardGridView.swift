import AppKit

@MainActor
final class SkillCardGridView: NSView {
    private static let gap: CGFloat = 12
    private static let twoColumnMinimumWidth: CGFloat = 560

    private let cards: [SkillCardView]

    override var isFlipped: Bool { true }

    init(cards: [SkillCardView]) {
        self.cards = cards
        super.init(frame: NSRect(x: 0, y: 0, width: 712, height: 400))
        cards.forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Never shorter than the viewport, so the grid stays pinned to the top.
    func fit(width: CGFloat, minimumHeight: CGFloat) {
        let frames = cardFrames(forWidth: width)
        let contentHeight = frames.map(\.maxY).max() ?? 0
        setFrameSize(NSSize(width: width, height: max(minimumHeight, contentHeight)))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for (card, frame) in zip(cards, cardFrames(forWidth: bounds.width)) {
            card.frame = frame
        }
    }

    private func cardFrames(forWidth width: CGFloat) -> [NSRect] {
        let columns = width >= Self.twoColumnMinimumWidth ? 2 : 1
        let cardWidth = (width - Self.gap * CGFloat(columns - 1)) / CGFloat(columns)
        var frames: [NSRect] = []
        var top: CGFloat = 0
        for rowStart in stride(from: 0, to: cards.count, by: columns) {
            let row = cards[rowStart..<min(rowStart + columns, cards.count)]
            let rowHeight = row.map { $0.height(forWidth: cardWidth) }.max() ?? 0
            for (offset, _) in row.enumerated() {
                frames.append(NSRect(
                    x: CGFloat(offset) * (cardWidth + Self.gap), y: top,
                    width: cardWidth, height: rowHeight))
            }
            top += rowHeight + Self.gap
        }
        return frames
    }
}
