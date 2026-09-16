import AppKit
import JarvisCore

/// One `detail` drawn as a document: its prose, then the code block, then the diagram. Every section
/// wraps at the viewport width without changing what the model sent.
@MainActor
final class DetailDocumentView: NSView {
    private let prose = NSTextView()
    private let code = NSTextView()
    private let drawing = NSImageView()
    private var rendered: (detail: ReplyDetail, fontSize: CGFloat)?
    private var drawnDiagram: (diagram: DiagramHint, size: NSSize)?
    override var isFlipped: Bool { true }
    var codeText: NSAttributedString { code.attributedString() }
    var proseText: String { prose.string }
    var hasDiagram: Bool { !drawing.isHidden }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [prose, code] {
            view.isEditable = false
            view.isSelectable = false
            view.drawsBackground = false
            view.textContainerInset = NSSize(width: 12, height: 8)
            view.isVerticallyResizable = true
            view.isHorizontallyResizable = false
            view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
            view.textContainer?.widthTracksTextView = true
            view.textContainer?.containerSize = view.maxSize
            addSubview(view)
        }
        prose.setAccessibilityLabel("Detail")
        code.setAccessibilityLabel("Code block")
        drawing.imageScaling = .scaleProportionallyUpOrDown
        drawing.setAccessibilityLabel("Diagram")
        addSubview(drawing)
    }

    required init?(coder: NSCoder) { fatalError("built in code; this project has no nibs") }

    /// Skip re-rendering text that is already on screen. A single resize frame reaches here three
    /// times over: the panel refreshes the box, measures its preferred height, then lays out,
    /// shrinking the font until the content fits. Only that last loop changes what is rendered, and
    /// `fit` reflows the existing text storage, so a skipped render still answers the new width.
    func show(_ detail: ReplyDetail, fontSize: CGFloat) {
        guard rendered?.detail != detail || rendered?.fontSize != fontSize else { return }
        rendered = (detail, fontSize)
        prose.textStorage?.setAttributedString(
            DetailProseFormatting.render(detail.prose, fontSize: fontSize))
        prose.isHidden = detail.prose.characters.isEmpty
        if let block = detail.code {
            code.textStorage?.setAttributedString(
                CodeBlockFormatting.render(block, fontSize: fontSize))
            code.isHidden = false
        } else {
            code.textStorage?.setAttributedString(NSAttributedString())
            code.isHidden = true
        }
        drawing.isHidden = detail.diagram == nil
        if detail.diagram == nil {
            drawing.image = nil
            drawnDiagram = nil
        }
    }

    func fit(viewportWidth: CGFloat) {
        let width = max(1, viewportWidth)
        var y: CGFloat = 0
        for view in [prose, code] where !view.isHidden {
            view.setFrameSize(NSSize(width: width, height: view.frame.height))
            guard let container = view.textContainer, let manager = view.layoutManager else { continue }
            container.containerSize = NSSize(
                width: max(1, width - 2 * view.textContainerInset.width),
                height: .greatestFiniteMagnitude)
            manager.ensureLayout(for: container)
            let height = ceil(manager.usedRect(for: container).height)
                + 2 * view.textContainerInset.height
            view.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height
        }
        if let diagram = rendered?.detail.diagram {
            // A diagram is drawn wide and short; the box scrolls, so give it a readable slice
            // rather than whatever is left over.
            let size = NSSize(width: max(1, width - 28), height: max(60, min(220, width * 0.5)))
            drawing.frame = NSRect(x: 14, y: y + 6, width: size.width, height: size.height)
            if drawnDiagram?.diagram != diagram || drawnDiagram?.size != size {
                drawing.image = DiagramHintImage.render(diagram, fitting: size)
                drawnDiagram = (diagram, size)
            }
            y = drawing.frame.maxY + 8
        }
        setFrameSize(NSSize(width: width, height: y))
    }
}
