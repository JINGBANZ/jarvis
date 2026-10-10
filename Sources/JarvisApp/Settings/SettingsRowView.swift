import AppKit

@MainActor
final class SettingsRowView: NSView {
    let controlView: NSView
    let preferredHeight: CGFloat

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let separator = SettingsStyle.separator()
    private let preferredControlSize: NSSize
    private let wrapsDetail: Bool

    init(
        title: String,
        detail: String? = nil,
        controlView: NSView,
        controlSize: NSSize = NSSize(width: SettingsStyle.controlWidth, height: 32),
        preferredHeight: CGFloat = SettingsStyle.rowHeight,
        wrapsDetail: Bool = false,
        showsSeparator: Bool = true
    ) {
        self.controlView = controlView
        self.preferredControlSize = controlSize
        self.preferredHeight = preferredHeight
        self.wrapsDetail = wrapsDetail
        super.init(frame: NSRect(x: 0, y: 0, width: 680, height: preferredHeight))
        autoresizingMask = [.width]

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = SettingsTheme.text

        detailLabel.stringValue = detail ?? ""
        detailLabel.font = .systemFont(ofSize: 11.5)
        detailLabel.textColor = SettingsTheme.mutedText
        detailLabel.lineBreakMode = wrapsDetail ? .byWordWrapping : .byTruncatingTail
        if wrapsDetail {
            detailLabel.maximumNumberOfLines = 0
            detailLabel.isSelectable = true
            detailLabel.cell?.wraps = true
            detailLabel.cell?.isScrollable = false
        }
        detailLabel.isHidden = detail == nil

        separator.isHidden = !showsSeparator
        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(controlView)
        addSubview(separator)
        setDetail(detail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setDetail(_ detail: String?, color: NSColor? = nil) {
        detailLabel.stringValue = detail ?? ""
        detailLabel.toolTip = detail
        detailLabel.textColor = color ?? SettingsTheme.mutedText
        if wrapsDetail {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineSpacing = 3
            detailLabel.attributedStringValue = NSAttributedString(string: detail ?? "", attributes: [
                .font: NSFont.systemFont(ofSize: 11.5),
                .foregroundColor: color ?? SettingsTheme.mutedText, .paragraphStyle: paragraph,
            ])
        }
        detailLabel.isHidden = detail == nil
        needsLayout = true
    }

    func setTitleColor(_ color: NSColor) {
        titleLabel.textColor = color
    }

    func height(for width: CGFloat) -> CGFloat {
        guard wrapsDetail, !detailLabel.isHidden else { return preferredHeight }
        let textHeight = detailLabel.cell?.cellSize(forBounds: NSRect(
            x: 0, y: 0, width: labelWidth(for: width), height: .greatestFiniteMagnitude)).height ?? 0
        return max(preferredHeight, ceil(textHeight) + 19 + 5 + 28)
    }

    private func controlWidth(for width: CGFloat) -> CGFloat {
        min(preferredControlSize.width, max(150, width * 0.52))
    }

    private func labelWidth(for width: CGFloat) -> CGFloat {
        max(80, width - SettingsStyle.rowHorizontalInset * 2 - controlWidth(for: width) - 12)
    }

    override func layout() {
        super.layout()

        let inset = SettingsStyle.rowHorizontalInset
        let controlWidth = controlWidth(for: bounds.width)
        let controlX = bounds.width - inset - controlWidth
        controlView.frame = NSRect(
            x: controlX,
            y: wrapsDetail ? bounds.height - 14 - preferredControlSize.height
                : (bounds.height - preferredControlSize.height) / 2,
            width: controlWidth,
            height: preferredControlSize.height)

        let labelWidth = labelWidth(for: bounds.width)
        if detailLabel.isHidden {
            titleLabel.frame = NSRect(
                x: inset,
                y: (bounds.height - 20) / 2,
                width: labelWidth,
                height: 20)
        } else if wrapsDetail {
            titleLabel.frame = NSRect(
                x: inset, y: bounds.height - 14 - 19, width: labelWidth, height: 19)
            detailLabel.frame = NSRect(
                x: inset, y: 14, width: labelWidth, height: max(0, titleLabel.frame.minY - 5 - 14))
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
