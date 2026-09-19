import AppKit
import JarvisCore

@MainActor
final class DetailDocumentView: NSView {
    private var proseViews: [(view: NSTextView, text: AttributedString)] = []
    private let code = DetailDocumentView.makeTextView(label: "Code block")
    private let drawing = NSImageView()
    /// Stands where a diagram still being written will appear.
    private let diagramPlaceholder = DetailDocumentView.makeTextView(label: "Diagram")
    private var stack: [NSView] = []
    private var rendered: (detail: ReplyDetail, fontSize: CGFloat, drawingDiagram: Bool)?
    private var drawnDiagram: (diagram: DiagramHint, available: NSSize)?
    override var isFlipped: Bool { true }
    var codeText: NSAttributedString { code.attributedString() }
    var proseText: String { proseViews.map(\.view.string).joined(separator: "\n\n") }
    var hasDiagram: Bool { stack.contains(drawing) }
    var diagramPlaceholderText: String? {
        stack.contains(diagramPlaceholder) ? diagramPlaceholder.string : nil
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawing.imageScaling = .scaleProportionallyUpOrDown
        drawing.setAccessibilityLabel("Diagram")
        diagramPlaceholder.textStorage?.setAttributedString(NSAttributedString(
            string: "Drawing diagram…",
            attributes: [.font: DetailView.secondaryTextFont,
                         .foregroundColor: DetailView.secondaryTextColor]))
    }

    required init?(coder: NSCoder) { fatalError("built in code; this project has no nibs") }

    private static func makeTextView(label: String) -> NSTextView {
        let view = NSTextView()
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
        view.setAccessibilityLabel(label)
        return view
    }

    /// Skips an unchanged render: one resize frame calls this several times, and `fit` reflows the
    /// existing text for the new width anyway. `drawingDiagram` adds the placeholder after the
    /// segments, where the diagram still being written will appear.
    func show(_ detail: ReplyDetail, fontSize: CGFloat, drawingDiagram: Bool = false) {
        guard rendered?.detail != detail || rendered?.fontSize != fontSize
                || rendered?.drawingDiagram != drawingDiagram else { return }
        if rendered?.detail != detail || rendered?.drawingDiagram != drawingDiagram {
            restack(detail.segments, drawingDiagram: drawingDiagram)
        }
        rendered = (detail, fontSize, drawingDiagram)
        for prose in proseViews {
            prose.view.textStorage?.setAttributedString(
                DetailProseFormatting.render(prose.text, fontSize: fontSize))
        }
        code.textStorage?.setAttributedString(
            detail.code.map { CodeBlockFormatting.render($0, fontSize: fontSize) }
                ?? NSAttributedString())
    }

    /// Subviews follow the stack because VoiceOver walks the hierarchy, not the frames.
    private func restack(_ segments: [ReplyDetail.Segment], drawingDiagram: Bool) {
        stack.forEach { $0.removeFromSuperview() }
        proseViews = []
        stack = segments.map { segment in
            switch segment {
            case .prose(let text):
                let view = Self.makeTextView(label: "Detail")
                proseViews.append((view, text))
                return view
            case .code: return code
            case .diagram: return drawing
            }
        } + (drawingDiagram ? [diagramPlaceholder] : [])
        stack.forEach(addSubview)
        if !hasDiagram {
            drawing.image = nil
            drawnDiagram = nil
        }
    }

    /// A diagram scales into the part of `viewportHeight` the prose and code leave, wherever it sits.
    func fit(viewportWidth: CGFloat, viewportHeight: CGFloat) {
        let width = max(1, viewportWidth)
        var textHeight: CGFloat = 0
        for case let view as NSTextView in stack {
            view.setFrameSize(NSSize(width: width, height: view.frame.height))
            guard let container = view.textContainer, let manager = view.layoutManager else { continue }
            container.containerSize = NSSize(
                width: max(1, width - 2 * view.textContainerInset.width),
                height: .greatestFiniteMagnitude)
            manager.ensureLayout(for: container)
            let height = ceil(manager.usedRect(for: container).height)
                + 2 * view.textContainerInset.height
            view.setFrameSize(NSSize(width: width, height: height))
            textHeight += height
        }
        if let diagram = rendered?.detail.diagram {
            // The 80 pt floor keeps a graph legible in a tiny box; the scroll view takes the rest.
            let available = NSSize(width: max(1, width - 28),
                                   height: max(80, viewportHeight - textHeight - 14))
            if drawnDiagram?.diagram != diagram || drawnDiagram?.available != available {
                drawing.image = DiagramHintImage.render(diagram, fitting: available)
                drawnDiagram = (diagram, available)
            }
            // Frame the drawn image, not the fitted box, so no unscrollable dead area surrounds it.
            drawing.setFrameSize(drawing.image?.size ?? available)
        }
        var y: CGFloat = 0
        for view in stack {
            if view === drawing {
                view.setFrameOrigin(NSPoint(x: 14, y: y + 6))
                y = view.frame.maxY + 8
            } else {
                view.setFrameOrigin(NSPoint(x: 0, y: y))
                y = view.frame.maxY
            }
        }
        setFrameSize(NSSize(width: width, height: y))
    }
}
