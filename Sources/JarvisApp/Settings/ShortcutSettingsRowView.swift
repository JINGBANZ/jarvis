import AppKit

@MainActor
final class ShortcutSettingsRowView: NSView {
    private let titleLabel: NSTextField
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let keyboard: NSView
    private let mouse: NSView
    private let separator = SettingsStyle.separator()
    private var keyboardDetail = ""
    private var keyboardColor: NSColor?
    private var mouseNotice: String?
    private var mouseColor: NSColor?

    static func height(for width: CGFloat) -> CGFloat { width < 530 ? 110 : 76 }

    init(title: String, keyboard: NSView, mouse: NSView, showsSeparator: Bool) {
        titleLabel = NSTextField(labelWithString: title)
        self.keyboard = keyboard
        self.mouse = mouse
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = SettingsTheme.text
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.maximumNumberOfLines = 2
        separator.isHidden = !showsSeparator
        [titleLabel, detailLabel, keyboard, mouse, separator].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setDetail(_ text: String, color: NSColor? = nil) {
        keyboardDetail = text
        keyboardColor = color
        renderDetail()
    }

    func setMouseNotice(_ text: String?, color: NSColor?) {
        mouseNotice = text
        mouseColor = color
        renderDetail()
    }

    private func renderDetail() {
        detailLabel.stringValue = mouseNotice ?? keyboardDetail
        detailLabel.textColor = (mouseNotice == nil ? keyboardColor : mouseColor) ?? SettingsTheme.mutedText
        detailLabel.setAccessibilityHelp(detailLabel.stringValue)
    }

    override func layout() {
        super.layout()
        let inset = SettingsStyle.rowHorizontalInset
        let narrow = bounds.width < 530
        let keyboardWidth: CGFloat = 106
        let mouseWidth: CGFloat = 136
        let controlY = narrow ? 12 : (bounds.height - 28) / 2
        let mouseX = bounds.width - inset - mouseWidth
        let keyboardX = narrow ? inset : mouseX - 12 - keyboardWidth
        keyboard.frame = NSRect(x: keyboardX, y: controlY, width: keyboardWidth, height: 28)
        mouse.frame = NSRect(x: mouseX, y: controlY, width: mouseWidth, height: 28)
        let textWidth = narrow ? bounds.width - inset * 2 : keyboardX - inset - 12
        titleLabel.frame = NSRect(x: inset, y: bounds.height - 29, width: textWidth, height: 19)
        detailLabel.frame = NSRect(x: inset, y: bounds.height - 59, width: textWidth, height: 28)
        separator.frame = NSRect(x: inset, y: bounds.height - 1, width: bounds.width - inset, height: 1)
    }
}
