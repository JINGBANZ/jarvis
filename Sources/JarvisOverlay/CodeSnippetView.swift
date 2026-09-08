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
    private let document = CodeSnippetDocumentView(frame: .zero)
    private(set) var snippet: CodeSnippet?
    var codeText: NSAttributedString { document.codeText }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // This opaque backing deliberately does not inherit the history's configurable opacity.
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
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = document
        for view in [title, dismissButton, scroll] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 14, y: bounds.height - 25, width: max(0, bounds.width - 100), height: 18)
        dismissButton.frame = NSRect(x: bounds.width - 78, y: bounds.height - 27, width: 66, height: 22)
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - 28))
        document.fit(viewportWidth: scroll.contentSize.width)
    }

    func show(_ snippet: CodeSnippet?, fontSize: CGFloat) {
        let changed = self.snippet != snippet
        self.snippet = snippet
        isHidden = snippet == nil
        guard let snippet else { return }
        title.stringValue = snippet.language.isEmpty ? "CODE" : "CODE · \(snippet.language)"
        document.show(snippet, fontSize: fontSize)
        document.fit(viewportWidth: max(1, bounds.width))
        if changed { scroll.contentView.scroll(to: .zero) }
        needsLayout = true
    }

    @objc private func dismiss() { onDismiss?() }
}
