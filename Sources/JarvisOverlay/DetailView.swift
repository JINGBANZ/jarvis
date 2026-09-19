import AppKit
import JarvisCore

/// Never give a control a `toolTip`: AppKit draws it in its own window, outside capture exclusion.
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
    /// Which reply's detail is on screen, so a detail that grows keeps the reader's scroll position.
    private var shownOrigin: (stamp: String, index: Int?)?
    private(set) var isRolled = false
    private var chrome: OverlayBoxChrome
    var stripHeight: CGFloat { chrome.height }
    var iconPointSize: CGFloat { chrome.iconPointSize }
    var titlePointSize: CGFloat { chrome.titlePointSize }

    var codeText: NSAttributedString { document.codeText }
    var proseText: String { document.proseText }
    var showsDiagram: Bool { !isRolled && document.hasDiagram }
    var titleText: String { title.stringValue }
    var positionText: String { position.stringValue }

    init(frame: NSRect,
         chrome: OverlayBoxChrome = OverlayBoxChrome(contentHeight: CGFloat(Defaults.Overlay.Box.height))) {
        self.chrome = chrome
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Self.background.cgColor
        title.textColor = NSColor(white: 0.86, alpha: 1)
        title.lineBreakMode = .byTruncatingTail
        position.textColor = NSColor(white: 1, alpha: 0.5)
        for button in [previousButton, nextButton, pinButton, dismissButton] {
            button.target = self
        }
        applyChrome()
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

    func apply(_ chrome: OverlayBoxChrome) {
        guard chrome != self.chrome else { return }
        self.chrome = chrome
        applyChrome()
        needsLayout = true
    }

    private func applyChrome() {
        title.font = .systemFont(ofSize: chrome.titlePointSize, weight: .semibold)
        position.font = .monospacedDigitSystemFont(ofSize: chrome.titlePointSize, weight: .regular)
        let radius = (chrome.button * 0.22).rounded()
        for button in [previousButton, nextButton, pinButton, dismissButton] {
            button.apply(iconPointSize: chrome.iconPointSize, cornerRadius: radius)
        }
    }

    override func layout() {
        super.layout()
        let top = bounds.height - stripHeight
        let buttonY = top + ((stripHeight - chrome.button) / 2).rounded()
        var x = bounds.width - chrome.inset
        for button in [dismissButton, pinButton, nextButton, previousButton] {
            x -= chrome.button
            button.frame = NSRect(x: x, y: buttonY, width: chrome.button, height: chrome.button)
            x -= 2
        }
        let labelHeight = title.intrinsicContentSize.height.rounded(.up)
        let labelY = top + ((stripHeight - labelHeight) / 2).rounded()
        let positionWidth = position.stringValue.isEmpty
            ? 0
            : position.intrinsicContentSize.width.rounded(.up)
        position.frame = NSRect(x: max(0, x - positionWidth - chrome.inset), y: labelY,
                                width: positionWidth, height: labelHeight)
        title.frame = NSRect(x: chrome.inset, y: labelY,
                             width: max(0, position.frame.minX - chrome.inset * 2),
                             height: labelHeight)
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, top))
        emptyLabel.frame = NSRect(x: chrome.inset, y: 12,
                                  width: max(0, bounds.width - chrome.inset * 2),
                                  height: max(0, top - 16))
        guard let detail, !isRolled else { return }
        var size = preferredFontSize
        while true {
            document.show(detail, fontSize: size)
            document.fit(viewportWidth: scroll.contentSize.width,
                         viewportHeight: scroll.contentSize.height)
            if detail.diagram != nil || document.frame.height <= scroll.contentSize.height || size <= 12 { break }
            size = max(12, size - 1)
        }
    }

    /// `position.index` is zero-based.
    func show(_ detail: ReplyDetail?, stamp: String, position slot: (index: Int, count: Int)?,
              isHeld: Bool, isRolled: Bool, fontSize: CGFloat, enabled: Bool = true) {
        preferredFontSize = min(18, max(12, fontSize))
        let origin = (stamp: stamp, index: slot?.index)
        let changed = shownOrigin.map { $0 != origin } ?? true
        shownOrigin = origin
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
        document.fit(viewportWidth: max(1, bounds.width),
                     viewportHeight: max(1, bounds.height - stripHeight))
        if changed { scroll.contentView.scroll(to: .zero) }
    }

    /// `viewportHeight` is the tallest body the panel would grant; readable overflow scrolls.
    func preferredHeight(viewportWidth: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        guard let detail, !isRolled else { return stripHeight }
        document.show(detail, fontSize: preferredFontSize)
        document.fit(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
        return stripHeight + document.frame.height
    }

    @objc private func stepBack() { onPrevious?() }
    @objc private func stepForward() { onNext?() }
    @objc private func togglePin() { onTogglePin?() }
    @objc private func toggleRolled() { onToggleRolled?() }
}
