import AppKit
import JarvisCore

/// The detail box: the lower section of the Overlay Box panel. Its title strip says which reply the
/// detail came from and where it sits in the session, and carries the controls that move and hold
/// it; the body below scrolls independently, so new coaching history never moves a diagram or a code
/// block under the user's eyes.
///
/// None of the controls carries a `toolTip`: AppKit draws one in a window of its own, which does not
/// inherit the panel's capture exclusion. They carry accessibility labels instead, the same rule the
/// header buttons follow.
@MainActor
final class DetailView: NSView {
    static let background = NSColor(srgbRed: 0.055, green: 0.07, blue: 0.10, alpha: 1)

    let previousButton = OverlayBoxHeaderButton(symbol: "chevron.left", label: "Earlier detail")
    let nextButton = OverlayBoxHeaderButton(symbol: "chevron.right", label: "Later detail")
    let pinButton = OverlayBoxHeaderButton(symbol: "pin", label: "Hold this detail")
    let dismissButton = OverlayBoxHeaderButton(symbol: "xmark", label: "Dismiss detail")

    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var onToggleRolled: (() -> Void)?

    private let title = NSTextField(labelWithString: "")
    private let position = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(wrappingLabelWithString:
        "Code, diagrams, and explanations appear here.")
    private let document = DetailDocumentView(frame: .zero)
    private var preferredFontSize: CGFloat = 18
    private(set) var detail: ReplyDetail?
    private(set) var isRolled = false
    /// The strip's height: the title, the position, and the four controls sit in it.
    static let stripHeight: CGFloat = 28

    var codeText: NSAttributedString { document.codeText }
    var proseText: String { document.proseText }
    var showsDiagram: Bool { !isRolled && document.hasDiagram }
    var titleText: String { title.stringValue }
    var positionText: String { position.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // The detail backdrop has its own opacity, independent of the history fill.
        layer?.backgroundColor = Self.background.cgColor
        title.textColor = NSColor(white: 0.86, alpha: 1)
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        position.textColor = NSColor(white: 1, alpha: 0.5)
        position.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        for button in [previousButton, nextButton, pinButton, dismissButton] {
            button.apply(iconPointSize: 11, cornerRadius: 4)
            button.target = self
        }
        previousButton.action = #selector(stepBack)
        nextButton.action = #selector(stepForward)
        pinButton.action = #selector(togglePin)
        dismissButton.action = #selector(toggleRolled)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = document
        emptyLabel.textColor = NSColor(white: 0.8, alpha: 1)
        emptyLabel.font = .systemFont(ofSize: 13)
        for view in [title, position, previousButton, nextButton, pinButton, dismissButton,
                     scroll, emptyLabel] {
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("built in code; this project has no nibs") }

    override func layout() {
        super.layout()
        let top = bounds.height - Self.stripHeight
        var x = bounds.width - 10
        for button in [dismissButton, pinButton, nextButton, previousButton] {
            x -= 22
            button.frame = NSRect(x: x, y: top + 4, width: 20, height: 20)
            x -= 2
        }
        let positionWidth: CGFloat = position.stringValue.isEmpty ? 0 : 48
        position.frame = NSRect(x: max(0, x - positionWidth - 6), y: top + 5,
                                width: positionWidth, height: 18)
        title.frame = NSRect(x: 14, y: top + 5,
                             width: max(0, position.frame.minX - 20), height: 18)
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, top))
        emptyLabel.frame = NSRect(x: 14, y: 12, width: max(0, bounds.width - 28),
                                  height: max(0, top - 16))
        guard let detail, !isRolled else { return }
        // Keep the largest readable size that fits; a small box can still scroll vertically.
        var size = preferredFontSize
        while true {
            document.show(detail, fontSize: size)
            document.fit(viewportWidth: scroll.contentSize.width)
            if document.frame.height <= scroll.contentSize.height || size <= 12 { break }
            size = max(12, size - 1)
        }
    }

    /// - Parameters:
    ///   - stamp: the time of the reply this detail came from, so the strip names its hint.
    ///   - position: one-based place in the session's details, and how many there are.
    ///   - isHeld: whether the box is pinned or parked, which the pin control reflects.
    func show(_ detail: ReplyDetail?, stamp: String, position slot: (index: Int, count: Int)?,
              isHeld: Bool, isRolled: Bool, fontSize: CGFloat, enabled: Bool = true) {
        preferredFontSize = min(18, max(12, fontSize))
        let changed = self.detail != detail
        self.detail = detail
        self.isRolled = isRolled
        isHidden = !enabled
        title.stringValue = detail == nil || stamp.isEmpty ? "DETAIL" : "DETAIL · FROM \(stamp)"
        position.stringValue = slot.map { "\($0.index + 1) of \($0.count)" } ?? ""
        previousButton.isHidden = detail == nil
        nextButton.isHidden = detail == nil
        pinButton.isHidden = detail == nil
        dismissButton.isHidden = detail == nil
        previousButton.isEnabled = (slot?.index ?? 0) > 0
        nextButton.isEnabled = slot.map { $0.index + 1 < $0.count } ?? false
        pinButton.setSymbol(isHeld ? "pin.fill" : "pin",
                            label: isHeld ? "Release this detail" : "Hold this detail")
        dismissButton.setSymbol(isRolled ? "chevron.up" : "xmark",
                                label: isRolled ? "Show detail" : "Dismiss detail")
        emptyLabel.isHidden = detail != nil || isRolled
        scroll.isHidden = detail == nil || isRolled
        needsLayout = true
        guard let detail, !isRolled else { return }
        document.show(detail, fontSize: preferredFontSize)
        document.fit(viewportWidth: max(1, bounds.width))
        if changed { scroll.contentView.scroll(to: .zero) }
    }

    /// Measure wrapped content at the preferred size before allocating the box's bounded height.
    func preferredHeight(viewportWidth: CGFloat) -> CGFloat {
        guard let detail, !isRolled else { return Self.stripHeight }
        document.show(detail, fontSize: preferredFontSize)
        document.fit(viewportWidth: viewportWidth)
        return Self.stripHeight + document.frame.height
    }

    @objc private func stepBack() { onPrevious?() }
    @objc private func stepForward() { onNext?() }
    @objc private func togglePin() { onTogglePin?() }
    @objc private func toggleRolled() { onToggleRolled?() }
}
