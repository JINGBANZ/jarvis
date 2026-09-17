import AppKit

@MainActor
final class SettingsCardView: NSBox {
    /// Runs on every layout: AppKit doesn't tell the owner when an `NSStackView` resizes the card.
    var onLayout: (() -> Void)?

    private let headingLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let headerSeparator = SettingsStyle.separator()

    private(set) var headerHeight: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        boxType = .custom
        borderWidth = 1
        cornerRadius = SettingsStyle.cardCornerRadius
        borderColor = SettingsTheme.line
        fillColor = SettingsTheme.cardFill
        contentViewMargins = .zero

        detailLabel.font = .systemFont(ofSize: 11.5)
        detailLabel.textColor = SettingsTheme.dimText
        detailLabel.alignment = .right
        detailLabel.lineBreakMode = .byTruncatingTail
        headingLabel.isHidden = true
        detailLabel.isHidden = true
        headerSeparator.isHidden = true

        contentView?.addSubview(headingLabel)
        contentView?.addSubview(detailLabel)
        contentView?.addSubview(headerSeparator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setHeader(title: String, detail: String? = nil) {
        headerHeight = SettingsStyle.cardHeaderHeight
        headingLabel.attributedStringValue = NSAttributedString(string: title.uppercased(), attributes: [
            .kern: 2, .font: NSFont.boldSystemFont(ofSize: 10.5), .foregroundColor: SettingsTheme.purple,
        ])
        headingLabel.isHidden = false
        detailLabel.stringValue = detail ?? ""
        detailLabel.toolTip = detail
        detailLabel.isHidden = detail == nil
        headerSeparator.isHidden = false
        needsLayout = true
    }

    var bodyFrame: NSRect {
        NSRect(
            x: 0,
            y: 0,
            width: contentView?.bounds.width ?? bounds.width,
            height: max(0, (contentView?.bounds.height ?? bounds.height) - headerHeight))
    }

    override func layout() {
        super.layout()
        if let content = contentView, headerHeight > 0 {
            let y = content.bounds.height - headerHeight
            let inset = SettingsStyle.rowHorizontalInset
            // The detail takes whatever the title leaves, so a sentence-long detail still reads.
            let headingWidth = min(ceil(headingLabel.fittingSize.width), content.bounds.width * 0.55)
            headingLabel.frame = NSRect(x: inset, y: y + 13, width: headingWidth, height: 18)
            let detailX = inset + headingWidth + 12
            detailLabel.frame = NSRect(
                x: detailX,
                y: y + 13,
                width: max(0, content.bounds.width - inset - detailX),
                height: 18)
            headerSeparator.frame = NSRect(
                x: 0,
                y: y,
                width: content.bounds.width,
                height: 1)
        }
        onLayout?()
    }
}
