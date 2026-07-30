import AppKit

/// One standard label/help/control row used inside Settings cards.
///
/// Owners still create the real AppKit control and keep its target/action behavior; this view owns
/// only the shared row rhythm and responsive trailing alignment.
@MainActor
final class SettingsRowView: NSView {
    let controlView: NSView
    let preferredHeight: CGFloat

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let separator = SettingsStyle.separator()
    private let preferredControlSize: NSSize

    init(
        title: String,
        detail: String? = nil,
        controlView: NSView,
        controlSize: NSSize = NSSize(width: SettingsStyle.controlWidth, height: 32),
        preferredHeight: CGFloat = SettingsStyle.rowHeight,
        showsSeparator: Bool = true
    ) {
        self.controlView = controlView
        self.preferredControlSize = controlSize
        self.preferredHeight = preferredHeight
        super.init(frame: NSRect(x: 0, y: 0, width: 680, height: preferredHeight))
        autoresizingMask = [.width]

        titleLabel.stringValue = title
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        detailLabel.stringValue = detail ?? ""
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.isHidden = detail == nil

        separator.isHidden = !showsSeparator
        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(controlView)
        addSubview(separator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()

        let inset = SettingsStyle.rowHorizontalInset
        let controlWidth = min(
            preferredControlSize.width,
            max(150, bounds.width * 0.52))
        let controlX = bounds.width - inset - controlWidth
        controlView.frame = NSRect(
            x: controlX,
            y: (bounds.height - preferredControlSize.height) / 2,
            width: controlWidth,
            height: preferredControlSize.height)

        let labelWidth = max(80, controlX - inset - 12)
        if detailLabel.isHidden {
            titleLabel.frame = NSRect(
                x: inset,
                y: (bounds.height - 20) / 2,
                width: labelWidth,
                height: 20)
        } else {
            titleLabel.frame = NSRect(
                x: inset,
                y: bounds.height / 2 + 1,
                width: labelWidth,
                height: 19)
            detailLabel.frame = NSRect(
                x: inset,
                y: bounds.height / 2 - 16,
                width: labelWidth,
                height: 16)
        }

        separator.frame = NSRect(x: inset, y: bounds.height - 1, width: bounds.width - inset, height: 1)
    }
}
