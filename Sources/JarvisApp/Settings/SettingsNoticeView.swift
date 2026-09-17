import AppKit

@MainActor
final class SettingsNoticeView: NSBox {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let button: NSButton?
    private let action: (() -> Void)?

    init(text: String, actionTitle: String?, action: (() -> Void)?) {
        self.action = action
        button = actionTitle.map { NSButton(title: $0, target: nil, action: nil) }
        super.init(frame: NSRect(x: 0, y: 0, width: 712, height: 44))
        boxType = .custom
        borderWidth = 1
        cornerRadius = 10
        borderColor = SettingsTheme.amber
        fillColor = SettingsTheme.noticeFill
        contentViewMargins = .zero
        label.attributedStringValue = Self.styled(text)
        contentView?.addSubview(label)
        if let button {
            button.bezelStyle = .rounded
            button.target = self
            button.action = #selector(fix)
            contentView?.addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func styled(_ text: String) -> NSAttributedString {
        let split = text.range(of: ". ")
        let lead = split.map { String(text[..<$0.upperBound]) } ?? text
        let rest = split.map { String(text[$0.upperBound...]) } ?? ""
        let result = NSMutableAttributedString(string: lead, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 12.5), .foregroundColor: SettingsTheme.amber,
        ])
        result.append(NSAttributedString(string: rest, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: SettingsTheme.text,
        ]))
        return result
    }

    private var buttonWidth: CGFloat {
        button.map { ceil($0.fittingSize.width) + 12 } ?? 0
    }

    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        let textWidth = max(80, width - 28 - buttonWidth)
        let text = label.cell?.cellSize(forBounds: NSRect(
            x: 0, y: 0, width: textWidth, height: .greatestFiniteMagnitude)).height ?? 18
        return max(44, ceil(text) + 22)
    }

    override func layout() {
        super.layout()
        guard let content = contentView else { return }
        let textWidth = max(80, content.bounds.width - 28 - buttonWidth)
        label.frame = NSRect(x: 14, y: 11, width: textWidth, height: content.bounds.height - 22)
        if let button {
            let size = button.fittingSize
            button.frame = NSRect(x: content.bounds.width - 14 - size.width,
                                  y: (content.bounds.height - size.height) / 2,
                                  width: size.width, height: size.height)
        }
    }

    @objc private func fix() {
        action?()
    }
}
