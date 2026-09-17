import AppKit
import JarvisCore

@MainActor
final class SkillCardView: NSView {
    private static let padding: CGFloat = 14
    private static let iconSize: CGFloat = 42
    private static let gap: CGFloat = 12

    private let icon = NSImageView()
    private let titleLabel: NSTextField
    private let toggle = NSSwitch()
    private let descriptionLabel: NSTextField
    private let statusLabel = NSTextField(labelWithString: "")
    private let onToggle: (Bool) -> Void

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    init(skill: Skill, isOn: Bool, onToggle: @escaping (Bool) -> Void) {
        self.onToggle = onToggle
        titleLabel = NSTextField(labelWithString: skill.displayTitle)
        descriptionLabel = NSTextField(wrappingLabelWithString: skill.description)
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 120))
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1

        icon.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 18, weight: .medium)
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 10
        titleLabel.font = .boldSystemFont(ofSize: 13.5)
        titleLabel.textColor = SettingsTheme.text
        descriptionLabel.font = .systemFont(ofSize: 11.8)
        descriptionLabel.textColor = SettingsTheme.mutedText
        statusLabel.font = .boldSystemFont(ofSize: 9.5)
        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.setAccessibilityLabel("\(skill.displayTitle) skill")
        toggle.identifier = NSUserInterfaceItemIdentifier("skill-\(skill.name)")
        [icon, titleLabel, toggle, descriptionLabel, statusLabel].forEach(addSubview)
        applyState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var textX: CGFloat { Self.padding + Self.iconSize + Self.gap }

    func height(forWidth width: CGFloat) -> CGFloat {
        let textWidth = max(60, width - textX - Self.padding)
        return Self.padding + 24 + 4 + descriptionHeight(forWidth: textWidth) + 8 + 12 + Self.padding
    }

    override func layout() {
        super.layout()
        let textWidth = max(60, bounds.width - textX - Self.padding)
        icon.frame = NSRect(x: Self.padding, y: Self.padding, width: Self.iconSize, height: Self.iconSize)
        toggle.frame = NSRect(x: bounds.width - Self.padding - 40, y: Self.padding, width: 40, height: 24)
        titleLabel.frame = NSRect(x: textX, y: Self.padding + 3, width: textWidth - 48, height: 18)
        descriptionLabel.frame = NSRect(
            x: textX, y: Self.padding + 28, width: textWidth, height: descriptionHeight(forWidth: textWidth))
        statusLabel.frame = NSRect(
            x: textX, y: descriptionLabel.frame.maxY + 8, width: textWidth, height: 12)
    }

    override func updateLayer() {
        let isOn = toggle.state == .on
        layer?.backgroundColor = SettingsTheme.cardFill.cgColor
        layer?.borderColor = (isOn ? SettingsTheme.teal : SettingsTheme.line).cgColor
        icon.layer?.backgroundColor = SettingsTheme.iconWell.cgColor
    }

    private func descriptionHeight(forWidth width: CGFloat) -> CGFloat {
        let size = descriptionLabel.cell?.cellSize(forBounds: NSRect(
            x: 0, y: 0, width: width, height: .greatestFiniteMagnitude))
        return ceil(size?.height ?? 16)
    }

    private func applyState() {
        let isOn = toggle.state == .on
        let tint = isOn ? SettingsTheme.teal : SettingsTheme.dimText
        statusLabel.attributedStringValue = NSAttributedString(
            string: isOn ? "EQUIPPED" : "UNEQUIPPED",
            attributes: [.kern: 1.6, .font: NSFont.boldSystemFont(ofSize: 9.5), .foregroundColor: tint])
        icon.contentTintColor = tint
        alphaValue = isOn ? 1 : 0.55
        needsDisplay = true
    }

    @objc private func toggled(_ sender: NSSwitch) {
        applyState()
        onToggle(sender.state == .on)
    }
}
