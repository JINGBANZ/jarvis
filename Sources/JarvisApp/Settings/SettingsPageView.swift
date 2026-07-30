import AppKit

/// The common full-tab shell: one page title, one short explanation, an optional status badge, and
/// a content region with identical outer spacing on every Settings page.
@MainActor
final class SettingsPageView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let statusBox = NSBox()
    private let statusLabel = NSTextField(labelWithString: "")
    private let bodyView: NSView

    init(
        title: String,
        summary: String,
        status: String? = nil,
        bodyView: NSView
    ) {
        self.bodyView = bodyView
        super.init(frame: NSRect(x: 0, y: 0, width: 760, height: 560))
        autoresizingMask = [.width, .height]

        titleLabel.stringValue = title
        titleLabel.font = .boldSystemFont(ofSize: 21)
        titleLabel.setAccessibilityLabel("\(title) settings")

        summaryLabel.stringValue = summary
        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail

        statusLabel.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .systemGreen
        statusLabel.alignment = .center
        statusBox.boxType = .custom
        statusBox.borderWidth = 1
        statusBox.cornerRadius = 10
        statusBox.borderColor = NSColor.systemGreen.withAlphaComponent(0.22)
        statusBox.fillColor = NSColor.systemGreen.withAlphaComponent(0.09)
        statusBox.contentViewMargins = .zero
        statusBox.contentView?.addSubview(statusLabel)

        addSubview(titleLabel)
        addSubview(summaryLabel)
        addSubview(statusBox)
        addSubview(bodyView)
        setStatus(status)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setStatus(_ status: String?) {
        let value = status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        statusLabel.stringValue = value
        statusBox.isHidden = value.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()

        let inset = SettingsStyle.pageHorizontalInset
        let headerTop = bounds.height - SettingsStyle.pageTopInset
        let headerBottom = headerTop - SettingsStyle.pageHeaderHeight
        let availableWidth = max(0, bounds.width - inset * 2)

        titleLabel.frame = NSRect(
            x: inset,
            y: headerTop - 25,
            width: max(0, availableWidth - 150),
            height: 25)
        summaryLabel.frame = NSRect(
            x: inset,
            y: headerBottom + 1,
            width: max(0, availableWidth - 150),
            height: 18)

        if !statusBox.isHidden {
            statusLabel.sizeToFit()
            let badgeWidth = max(78, statusLabel.frame.width + 20)
            statusBox.frame = NSRect(
                x: bounds.width - inset - badgeWidth,
                y: headerBottom + 11,
                width: badgeWidth,
                height: 24)
            statusLabel.frame = NSRect(x: 8, y: 3, width: badgeWidth - 16, height: 18)
        }

        let bodyTop = headerBottom - SettingsStyle.pageHeaderSpacing
        bodyView.frame = NSRect(
            x: inset,
            y: SettingsStyle.pageBottomInset,
            width: availableWidth,
            height: max(0, bodyTop - SettingsStyle.pageBottomInset))
    }
}
