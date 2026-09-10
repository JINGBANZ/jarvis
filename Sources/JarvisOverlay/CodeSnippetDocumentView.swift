import AppKit
import JarvisCore

/// Placement wraps at the viewport width while code retains its original line breaks and indentation.
@MainActor
final class CodeSnippetDocumentView: NSView {
    private let placement = NSTextField(wrappingLabelWithString: "")
    private let textView = NSTextView()
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
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = textView.maxSize
        textView.setAccessibilityLabel("Code snippet")
        addSubview(placement)
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ snippet: CodeSnippet, fontSize: CGFloat) {
        placement.stringValue = snippet.placement
        textView.textStorage?.setAttributedString(CodeSnippetFormatting.render(snippet, fontSize: fontSize))
        textView.sizeToFit()
    }

    func fit(viewportWidth: CGFloat) {
        let width = max(1, viewportWidth - 28)
        let height = max(18, ceil(placement.attributedStringValue.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height))
        placement.frame = NSRect(x: 14, y: 4, width: width, height: height)
        textView.setFrameOrigin(NSPoint(x: 0, y: height + 6))
        setFrameSize(NSSize(width: max(viewportWidth, textView.frame.width),
            height: textView.frame.maxY))
    }
}
