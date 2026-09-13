import AppKit
import JarvisCore

/// A session reference outside the scrolling history, within the existing private overlay window.
@MainActor
final class DiagramHintView: NSView {
    private let title = NSTextField(labelWithString: "HIGH-LEVEL DESIGN")
    private let drawing = NSImageView()
    private var diagram: DiagramHint?
    private var renderedDiagram: DiagramHint?
    private var renderedSize: NSSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Keep labels and connections legible independently of the history opacity setting.
        layer?.backgroundColor = NSColor(srgbRed: 0.055, green: 0.07, blue: 0.10, alpha: 1).cgColor
        title.textColor = NSColor(white: 0.86, alpha: 1)
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        drawing.imageScaling = .scaleProportionallyUpOrDown
        drawing.setAccessibilityLabel("High-level design diagram")
        addSubview(title)
        addSubview(drawing)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ diagram: DiagramHint?, enabled: Bool) {
        self.diagram = diagram
        isHidden = !enabled || diagram == nil
        if diagram == nil {
            drawing.image = nil
            renderedDiagram = nil
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 14, y: max(0, bounds.height - 25),
                             width: max(0, bounds.width - 28), height: 18)
        drawing.frame = NSRect(x: 14, y: 8, width: max(0, bounds.width - 28),
                               height: max(0, bounds.height - 40))
        guard !isHidden, let diagram, drawing.bounds.width > 0, drawing.bounds.height > 0 else { return }
        // Ordinary hints should not rasterize or replace the reference the user is reading.
        guard renderedDiagram != diagram || renderedSize != drawing.bounds.size else { return }
        drawing.image = DiagramHintImage.render(diagram, fitting: drawing.bounds.size)
        renderedDiagram = diagram
        renderedSize = drawing.bounds.size
    }
}
