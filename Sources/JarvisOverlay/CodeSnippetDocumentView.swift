import AppKit
import JarvisCore

/// Both sections wrap at the viewport width without changing the underlying code or highlights.
@MainActor
final class CodeSnippetDocumentView: NSView {
    private let placement = NSTextField(wrappingLabelWithString: "")
    private let textView = NSTextView()
    private var rendered: (snippet: CodeSnippet, fontSize: CGFloat)?
    override var isFlipped: Bool { true }
    var codeText: NSAttributedString { textView.attributedString() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        placement.textColor = .white
        placement.font = .systemFont(ofSize: 12, weight: .medium)
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = textView.maxSize
        textView.setAccessibilityLabel("Code snippet")
        addSubview(placement)
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Skip re-lexing text that is already on screen. A single resize frame reaches here three
    /// times over: the panel refreshes the dock, measures its preferred height, then lays out,
    /// shrinking the font until the code fits. Only that last loop changes what is rendered, and
    /// `fit` reflows the existing text storage, so a skipped render still answers the new width.
    func show(_ snippet: CodeSnippet, fontSize: CGFloat) {
        guard rendered?.snippet != snippet || rendered?.fontSize != fontSize else { return }
        rendered = (snippet, fontSize)
        placement.stringValue = snippet.placement
        textView.textStorage?.setAttributedString(CodeSnippetFormatting.render(snippet, fontSize: fontSize))
    }

    func fit(viewportWidth: CGFloat) {
        let width = max(1, viewportWidth - 28)
        let height = max(18, ceil(placement.attributedStringValue.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height))
        placement.frame = NSRect(x: 14, y: 4, width: width, height: height)
        // Constrain TextKit before measuring: sizeToFit with an unbounded container produces
        // a document wider than the dock and clips long code lines off its right edge.
        let textWidth = max(1, viewportWidth)
        textView.setFrameSize(NSSize(width: textWidth, height: textView.frame.height))
        if let container = textView.textContainer, let manager = textView.layoutManager {
            container.containerSize = NSSize(width: max(1, textWidth - 2 * textView.textContainerInset.width),
                                             height: .greatestFiniteMagnitude)
            manager.ensureLayout(for: container)
            let textHeight = ceil(manager.usedRect(for: container).height) + 2 * textView.textContainerInset.height
            textView.frame = NSRect(x: 0, y: height + 6, width: textWidth, height: textHeight)
        }
        setFrameSize(NSSize(width: textWidth, height: textView.frame.maxY))
    }
}
