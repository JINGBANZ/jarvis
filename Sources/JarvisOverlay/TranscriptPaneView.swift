import AppKit
import JarvisCore

/// The Overlay Box's live transcript column. Read-only text; it follows new rows unless the user
/// has scrolled up to read.
final class TranscriptPaneView: NSView {
    private static let fontSize: CGFloat = 13
    private static let myColor = NSColor(srgbRed: 0.36, green: 0.86, blue: 0.78, alpha: 1)
    private static let theirColor = NSColor(white: 1, alpha: 0.92)
    private static let handledAlpha: CGFloat = 0.42
    private static let inProgressAlpha: CGFloat = 0.55

    private let scroll = NSScrollView(frame: .zero)
    private let textView = PaneTextView(frame: .zero)
    private var shown: TranscriptPaneContent?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.06, alpha: 0.55).cgColor
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("built in code; this project has no nibs") }

    override var mouseDownCanMoveWindow: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scroll.frame = bounds
    }

    var attributedText: NSAttributedString { textView.attributedString() }

    func show(_ content: TranscriptPaneContent) {
        guard content != shown else { return }
        shown = content
        let followsLatest = isScrolledToBottom
        textView.textStorage?.setAttributedString(Self.render(content))
        if followsLatest { textView.scrollToEndOfDocument(nil) }
    }

    private var isScrolledToBottom: Bool {
        let visible = scroll.contentView.documentVisibleRect
        return visible.maxY >= textView.frame.height - 4
    }

    private static func render(_ content: TranscriptPaneContent) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (i, row) in content.rows.enumerated() {
            if i > 0 { result.append(NSAttributedString(string: "\n")) }
            let base = row.speaker == .me ? myColor : theirColor
            let alpha: CGFloat = switch row.state {
            case .handled: handledAlpha
            case .unhandled: base.alphaComponent
            case .inProgress: inProgressAlpha
            }
            let color = base.withAlphaComponent(alpha)
            let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
            let bodyFont = row.state == .inProgress
                ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                : font
            result.append(NSAttributedString(
                string: row.speaker == .me ? "You: " : "Them: ",
                attributes: [.foregroundColor: color,
                             .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)]))
            result.append(NSAttributedString(
                string: row.text, attributes: [.foregroundColor: color, .font: bodyFont]))
        }
        return result
    }
}

/// A plain `NSTextView` swallows the drag that should move the borderless window.
private final class PaneTextView: NSTextView {
    override var mouseDownCanMoveWindow: Bool { true }
}
