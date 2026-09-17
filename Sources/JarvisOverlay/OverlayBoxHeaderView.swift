import AppKit
import JarvisCore

/// Frame layout, not constraints, so it settles synchronously: an offscreen panel never runs a
/// layout pass.
final class OverlayBoxHeaderView: NSView {
    let collapseButton = OverlayBoxHeaderButton(symbol: "chevron.down", label: "Collapse")
    let clearButton = OverlayBoxHeaderButton(symbol: "eraser", label: "Clear history")
    private let titleLabel = MovableLabel(labelWithString: "Jarvis")
    private var chrome: OverlayBoxChrome
    private var showsSeparator = true
    var iconPointSize: CGFloat { chrome.iconPointSize }
    var titlePointSize: CGFloat { chrome.titlePointSize }

    init(chrome: OverlayBoxChrome) {
        self.chrome = chrome
        super.init(frame: .zero)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.alignment = .center
        titleLabel.textColor = NSColor(white: 1, alpha: 0.72)
        clearButton.isHidden = true
        addSubview(titleLabel)
        addSubview(collapseButton)
        addSubview(clearButton)
        applyChrome()
    }

    required init?(coder: NSCoder) { fatalError("built in code; this project has no nibs") }

    override var mouseDownCanMoveWindow: Bool { true }

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

    /// The chevron shows the current state, not the click's result (macOS disclosure convention).
    func setCollapsed(_ collapsed: Bool) {
        collapseButton.setSymbol(collapsed ? "chevron.right" : "chevron.down",
                                 label: collapsed ? "Expand" : "Collapse")
        showsSeparator = !collapsed
        needsDisplay = true
    }

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
        let titleHeight = titleLabel.intrinsicContentSize.height.rounded(.up)
        // Reserve both buttons' space even when clear is hidden, so the title never shifts.
        let titleInset = chrome.inset * 2 + chrome.button
        titleLabel.frame = NSRect(x: titleInset, y: ((bounds.height - titleHeight) / 2).rounded(),
                                  width: max(0, bounds.width - titleInset * 2), height: titleHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsSeparator else { return }
        NSColor(white: 1, alpha: 0.10).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// `NSControl` refuses the window drag by default.
private final class MovableLabel: NSTextField {
    override var mouseDownCanMoveWindow: Bool { true }
}
