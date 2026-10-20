import AppKit

@MainActor
final class GeneralSettingsView: NSView {
    var onSelectionChanged: (() -> Void)?
    private let pages: [NSView]
    private var buttons: [NSButton] = []
    private let separator = SettingsStyle.separator()
    private let heading = NSTextField(labelWithString: "Shortcuts")
    private var selected = 0

    init(shortcuts: NSView, privacy: NSView) {
        pages = [shortcuts, privacy]
        super.init(frame: NSRect(x: 0, y: 0, width: 772, height: 480))
        for (index, title) in ["Shortcuts", "Privacy"].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(selectTab))
            button.tag = index
            button.setButtonType(.pushOnPushOff)
            (button.cell as? NSButtonCell)?.showsStateBy = []
            (button.cell as? NSButtonCell)?.highlightsBy = []
            button.bezelStyle = .rounded
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.alignment = .left
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.image = NSImage(systemSymbolName: index == 0 ? "command" : "lock", accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel(title)
            buttons.append(button)
            addSubview(button)
        }
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        heading.textColor = SettingsTheme.text
        [separator, heading].forEach(addSubview)
        pages.forEach(addSubview)
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func selectTab(_ sender: NSButton) {
        window?.makeFirstResponder(sender)
        onSelectionChanged?()
        selected = sender.tag
        render()
    }

    private func render() {
        for (index, button) in buttons.enumerated() {
            button.state = index == selected ? .on : .off
            let tint = index == selected ? SettingsTheme.text : SettingsTheme.mutedText
            button.contentTintColor = tint
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: tint,
            ])
            button.layer?.backgroundColor = button.themedCGColor(index == selected ? SettingsTheme.iconWell : .clear)
            pages[index].isHidden = index != selected
        }
        heading.stringValue = buttons[selected].title
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        render()
    }

    override func layout() {
        super.layout()
        let sidebarWidth: CGFloat = bounds.width < 600 ? 114 : 140
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: 0, y: bounds.height - 36 - CGFloat(index) * 41,
                                  width: sidebarWidth - 15, height: 36)
        }
        separator.frame = NSRect(x: sidebarWidth, y: 0, width: 1, height: bounds.height)
        let x = sidebarWidth + 24
        let width = max(0, bounds.width - x)
        heading.frame = NSRect(x: x, y: bounds.height - 24, width: width, height: 24)
        for page in pages {
            page.frame = NSRect(x: x, y: 0, width: width, height: max(0, bounds.height - 40))
        }
    }
}
