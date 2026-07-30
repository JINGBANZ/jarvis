import AppKit

/// The shared rounded Settings group, with an optional standardized title/detail header.
///
/// AppKit does not notify a controller when an `NSStackView` changes an arranged view's width. This
/// small outer-edge adapter keeps layout responsibility with the card owner instead of teaching the
/// shared Settings window about any section's internal geometry.
@MainActor
final class SettingsCardView: NSBox {
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
        borderColor = .separatorColor
        fillColor = .controlBackgroundColor
        contentViewMargins = .zero

        headingLabel.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        headingLabel.textColor = .secondaryLabelColor
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.alignment = .right
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
        headingLabel.stringValue = title.uppercased()
        headingLabel.isHidden = false
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = detail == nil
        headerSeparator.isHidden = false
        needsLayout = true
    }

    /// The owner-controlled region below the optional group header.
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
            headingLabel.frame = NSRect(
                x: SettingsStyle.rowHorizontalInset,
                y: y + 13,
                width: max(120, content.bounds.width * 0.55),
                height: 18)
            detailLabel.frame = NSRect(
                x: content.bounds.width * 0.5,
                y: y + 13,
                width: max(0, content.bounds.width * 0.5 - SettingsStyle.rowHorizontalInset),
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
