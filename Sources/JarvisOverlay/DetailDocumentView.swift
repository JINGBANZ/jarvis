import AppKit
import JarvisCore

@MainActor
final class DetailDocumentView: NSView {
    private let prose = NSTextView()
    private let code = NSTextView()
    private let drawing = NSImageView()
    private var rendered: (detail: ReplyDetail, fontSize: CGFloat)?
    private var drawnDiagram: (diagram: DiagramHint, available: NSSize)?
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

    /// Skips an unchanged render: one resize frame calls this several times, and `fit` reflows the
    /// existing text for the new width anyway.
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

    /// A diagram uses the remaining viewport, scrolling at its readable minimum scale.
    func fit(viewportWidth: CGFloat, viewportHeight: CGFloat) {
        let width = max(1, viewportWidth)
        var documentWidth = width
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
            let available = NSSize(width: max(1, width - 28),
                                   height: max(1, viewportHeight - y - 14))
            if drawnDiagram?.diagram != diagram || drawnDiagram?.available != available {
                drawing.image = DiagramHintImage.render(diagram, fitting: available)
                drawnDiagram = (diagram, available)
            }
            // Frame the drawn image, not the fitted box, so no unscrollable dead area surrounds it.
            let drawn = drawing.image?.size ?? available
            drawing.frame = NSRect(x: 14, y: y + 6, width: drawn.width, height: drawn.height)
            documentWidth = max(width, drawing.frame.maxX + 14)
            y = drawing.frame.maxY + 8
        }
        setFrameSize(NSSize(width: documentWidth, height: y))
    }
}
