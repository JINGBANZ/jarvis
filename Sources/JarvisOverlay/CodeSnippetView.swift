import AppKit
import JarvisCore

/// Independent scrolling keeps new coaching history from moving the code under the user's eyes.
@MainActor
final class CodeSnippetView: NSView {
    static let background = NSColor(srgbRed: 0.055, green: 0.07, blue: 0.10, alpha: 1)
    let dismissButton = NSButton(title: "Dismiss", target: nil, action: nil)
    var onDismiss: (() -> Void)?
    private let title = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Code for your next coding hint will appear here.")
    private let document = CodeSnippetDocumentView(frame: .zero)
    private var preferredFontSize: CGFloat = 18
    private(set) var snippet: CodeSnippet?
    var codeText: NSAttributedString { document.codeText }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // The code backdrop has its own opacity, independent of the history fill.
        layer?.backgroundColor = Self.background.cgColor
        title.textColor = NSColor(white: 0.86, alpha: 1)
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        dismissButton.bezelStyle = .inline
        dismissButton.contentTintColor = .white
        // Inline button titles otherwise inherit dark text from a light system appearance.
        dismissButton.attributedTitle = NSAttributedString(string: "Dismiss", attributes: [
            .foregroundColor: NSColor(white: 0.85, alpha: 1),
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        ])
        dismissButton.target = self
        dismissButton.action = #selector(dismiss)
        dismissButton.setAccessibilityLabel("Dismiss code snippet")
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = document
        emptyLabel.textColor = NSColor(white: 0.8, alpha: 1)
        emptyLabel.font = .systemFont(ofSize: 13)
        for view in [title, dismissButton, scroll, emptyLabel] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 14, y: bounds.height - 25, width: max(0, bounds.width - 100), height: 18)
        dismissButton.frame = NSRect(x: bounds.width - 78, y: bounds.height - 27, width: 66, height: 22)
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - 28))
        emptyLabel.frame = NSRect(x: 14, y: 12, width: max(0, bounds.width - 28), height: max(0, bounds.height - 44))
        guard let snippet else { return }
        // Keep the largest readable size that fits; a tiny panel can still scroll vertically.
        var size = preferredFontSize
        while true {
            document.show(snippet, fontSize: size)
            document.fit(viewportWidth: scroll.contentSize.width)
            if document.frame.height <= scroll.contentSize.height || size <= 12 { break }
            size = max(12, size - 1)
        }
    }

    func show(_ snippet: CodeSnippet?, fontSize: CGFloat, enabled: Bool = true) {
        preferredFontSize = min(18, max(12, fontSize))
        let changed = self.snippet != snippet
        self.snippet = snippet
        isHidden = !enabled
        emptyLabel.isHidden = snippet != nil
        scroll.isHidden = snippet == nil
        dismissButton.isHidden = snippet == nil
        title.stringValue = "CODE"
        needsLayout = true
        guard let snippet else { return }
        title.stringValue = snippet.language.isEmpty ? "CODE" : "CODE · \(snippet.language)"
        document.show(snippet, fontSize: preferredFontSize)
        document.fit(viewportWidth: max(1, bounds.width))
        if changed { scroll.contentView.scroll(to: .zero) }
        needsLayout = true
    }

    /// Measure wrapped content at the preferred size before allocating the dock's bounded height.
    func preferredHeight(viewportWidth: CGFloat) -> CGFloat {
        guard let snippet else { return 96 }
        document.show(snippet, fontSize: preferredFontSize)
        document.fit(viewportWidth: viewportWidth)
        return 28 + document.frame.height
    }

    @objc private func dismiss() { onDismiss?() }
}
