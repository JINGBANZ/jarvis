import AppKit

/// Keeps the document at least as tall as the viewport, because AppKit anchors a short document at
/// the bottom and leaves an empty band above the first card.
@MainActor
final class SettingsCardStack {
    let scrollView = SettingsScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 560))

    private let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 760, height: 560))
    private var cards: [(view: NSView, height: NSLayoutConstraint)] = []

    init() {
        scrollView.autoresizingMask = [.width, .height]
        stack.orientation = .vertical
        stack.alignment = .width
        stack.distribution = .fill
        stack.spacing = SettingsStyle.sectionSpacing
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        stack.autoresizingMask = [.width]
    }

    /// Attaches the document only once complete: a partly built stack makes AppKit solve an
    /// impossible layout.
    func install(_ items: [(view: NSView, height: CGFloat)]) {
        for item in items {
            item.view.translatesAutoresizingMaskIntoConstraints = false
            let height = item.view.heightAnchor.constraint(equalToConstant: item.height)
            height.isActive = true
            stack.addArrangedSubview(item.view)
            // The stack's width alignment is only a low-priority preference, which a wrapping label's
            // intrinsic width outranks; a callout would then hug its text instead of filling the column.
            item.view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            cards.append((item.view, height))
        }
        let tail = NSView()
        tail.setContentHuggingPriority(.defaultLow, for: .vertical)
        tail.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        tail.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        if let last = cards.last?.view { stack.setCustomSpacing(0, after: last) }
        stack.addArrangedSubview(tail)

        scrollView.documentView = stack
        scrollView.onViewportChanged = { [weak self] in
            self?.recalculate()
            self?.revealTop()
        }
        recalculate()
        revealTop()
    }

    func setHeight(_ height: CGFloat, for view: NSView) {
        guard let card = cards.first(where: { $0.view === view }) else { return }
        card.height.constant = height
        recalculate()
    }

    func revealTop() {
        scrollView.contentView.scroll(to: NSPoint(
            x: 0,
            y: max(0, stack.bounds.height - scrollView.contentView.bounds.height)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func recalculate() {
        let heights = cards.map(\.height.constant)
        let contentHeight = heights.reduce(0, +)
            + CGFloat(max(0, heights.count - 1)) * SettingsStyle.sectionSpacing
        let viewportHeight = scrollView.contentView.bounds.height
        let height = max(contentHeight, viewportHeight)
        let oldHeight = stack.frame.height
        let oldOrigin = scrollView.contentView.bounds.origin.y
        let distanceFromTop = max(0, oldHeight - oldOrigin - viewportHeight)

        stack.frame.size.height = height
        stack.needsLayout = true
        stack.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(
            x: 0, y: max(0, height - viewportHeight - distanceFromTop)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
