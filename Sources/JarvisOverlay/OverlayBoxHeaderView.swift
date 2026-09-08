import AppKit

/// The Overlay Box's header strip: collapse on the left, "Jarvis" in the middle, clear on the right.
///
/// Frame layout rather than constraints. Every dimension comes from `OverlayBoxChrome` and changes on
/// each frame of a resize drag, so placing three rectangles directly is less machinery than restating
/// the same numbers as constraint constants, and it settles synchronously instead of waiting on a
/// layout pass an offscreen panel never runs.
final class OverlayBoxHeaderView: NSView {
    let collapseButton = OverlayBoxHeaderButton(symbol: "chevron.down", label: "Collapse")
    let clearButton = OverlayBoxHeaderButton(symbol: "eraser", label: "Clear history")
    private let titleLabel = MovableLabel(labelWithString: "Jarvis")
    private var chrome: OverlayBoxChrome
    /// Hidden while collapsed: with no log under it, the rule would underline nothing.
    private var showsSeparator = true

    var title: String { titleLabel.stringValue }

    init(chrome: OverlayBoxChrome) {
        self.chrome = chrome
        super.init(frame: .zero)
        titleLabel.alignment = .center
        titleLabel.textColor = NSColor(white: 1, alpha: 0.72)
        clearButton.isHidden = true          // nothing logged yet, so nothing to erase
        addSubview(titleLabel)
        addSubview(collapseButton)
        addSubview(clearButton)
        applyChrome()
    }

    required init?(coder: NSCoder) { fatalError("built in code; this project has no nibs") }

    /// A drag on the header moves the box, the way it does everywhere else on the panel.
    override var mouseDownCanMoveWindow: Bool { true }

    /// Rebuilding the title font and both symbol images on every frame of a resize drag would be work
    /// for nothing: the chrome only steps when the box crosses a rounding boundary.
    func apply(_ chrome: OverlayBoxChrome) {
        guard chrome != self.chrome else { return layoutControls() }
        self.chrome = chrome
        applyChrome()
    }

    private func applyChrome() {
        titleLabel.font = .systemFont(ofSize: chrome.titlePointSize, weight: .medium)
        let radius = (chrome.button * 0.22).rounded()
        collapseButton.apply(iconPointSize: chrome.iconPointSize, cornerRadius: radius)
        clearButton.apply(iconPointSize: chrome.iconPointSize, cornerRadius: radius)
        layoutControls()
    }

    /// The chevron states where the box is, not where the click will take it — the macOS disclosure
    /// convention, which is also what the menu bar and Settings use.
    func setCollapsed(_ collapsed: Bool) {
        collapseButton.setSymbol(collapsed ? "chevron.right" : "chevron.down",
                                 label: collapsed ? "Expand" : "Collapse")
        showsSeparator = !collapsed
        needsDisplay = true
    }

    /// The clear button exists only when there is something to erase, so an empty box carries no dead
    /// control. It keeps its space rather than collapsing out, so the title does not shift sideways
    /// when the first tip lands.
    func setHasContent(_ hasContent: Bool) {
        clearButton.isHidden = !hasContent
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutControls()
    }

    private func layoutControls() {
        let buttonY = ((bounds.height - chrome.button) / 2).rounded()
        collapseButton.frame = NSRect(x: chrome.inset, y: buttonY,
                                      width: chrome.button, height: chrome.button)
        clearButton.frame = NSRect(x: bounds.width - chrome.inset - chrome.button, y: buttonY,
                                   width: chrome.button, height: chrome.button)
        // Centred across the full width rather than in the gap between the buttons, so the name stays
        // put whether or not the clear button is on screen.
        let titleHeight = titleLabel.intrinsicContentSize.height.rounded(.up)
        titleLabel.frame = NSRect(x: 0, y: ((bounds.height - titleHeight) / 2).rounded(),
                                  width: bounds.width, height: titleHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsSeparator else { return }
        NSColor(white: 1, alpha: 0.10).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// A label that lets a drag on it move the borderless window, the way `MovableTextView` does for the
/// log. `NSControl` refuses the drag by default.
private final class MovableLabel: NSTextField {
    override var mouseDownCanMoveWindow: Bool { true }
}
