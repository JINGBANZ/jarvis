import AppKit

@MainActor
final class SettingsCalloutView: NSBox {
    enum Tone { case info, warning }

    static let preferredHeight: CGFloat = 60

    private let note: NSTextField

    init(text: String, tone: Tone = .info) {
        note = NSTextField(wrappingLabelWithString: text)
        super.init(frame: NSRect(x: 0, y: 0, width: 712, height: Self.preferredHeight))
        boxType = .custom
        borderWidth = 1
        cornerRadius = 10
        borderColor = tone == .warning ? SettingsTheme.amber : SettingsTheme.line
        fillColor = tone == .warning ? SettingsTheme.noticeFill : SettingsTheme.calloutFill
        contentViewMargins = .zero

        guard let content = contentView else { return }
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(
            systemSymbolName: tone == .warning ? "exclamationmark.triangle.fill" : "info.circle",
            accessibilityDescription: nil)
        icon.contentTintColor = tone == .warning ? SettingsTheme.amber : SettingsTheme.teal
        content.addSubview(icon)

        note.translatesAutoresizingMaskIntoConstraints = false
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = SettingsTheme.mutedText
        content.addSubview(note)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            note.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            note.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            note.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setText(_ text: String) {
        note.stringValue = text
    }
}
