import AppKit
import JarvisCore

/// The shell of every Settings page except the hub: a back button, the part's mini robot for the four
/// head pages, an uppercase title, one short explanation, an optional chip, an optional notice, and
/// the page body, with identical outer spacing on every page.
@MainActor
final class SettingsPageView: NSView {
    struct Chip: Equatable {
        enum Tone: Equatable { case neutral, live }
        let text: String
        let tone: Tone
        static func neutral(_ text: String) -> Chip { Chip(text: text, tone: .neutral) }
        static func live(_ text: String) -> Chip { Chip(text: text, tone: .live) }
    }

    /// Set by the Settings window when it builds the page. Nil hides the back button.
    var onBack: (() -> Void)? {
        didSet {
            backButton.isHidden = onBack == nil
            needsLayout = true
        }
    }

    private let backButton = SettingsBackButton()
    private let badge: RobotHeadView?
    private let titleLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let chipBox = NSBox()
    private let chipLabel = NSTextField(labelWithString: "")
    private var noticeView: SettingsNoticeView?
    private let bodyView: NSView

    init(title: String, summary: String, chip: Chip? = nil, part: RobotPart? = nil, bodyView: NSView) {
        self.bodyView = bodyView
        self.badge = part.map { RobotHeadView(style: .badge($0)) }
        super.init(frame: NSRect(x: 0, y: 0, width: 760, height: 560))
        autoresizingMask = [.width, .height]

        backButton.target = self
        backButton.action = #selector(back)
        backButton.isHidden = true

        titleLabel.attributedStringValue = NSAttributedString(string: title.uppercased(), attributes: [
            .kern: 5, .font: NSFont.systemFont(ofSize: 20, weight: .heavy),
            .foregroundColor: SettingsTheme.text,
        ])
        titleLabel.setAccessibilityLabel("\(title) settings")
        summaryLabel.stringValue = summary
        summaryLabel.font = .systemFont(ofSize: 12.5)
        summaryLabel.textColor = SettingsTheme.mutedText
        summaryLabel.lineBreakMode = .byTruncatingTail

        chipBox.boxType = .custom
        chipBox.borderWidth = 1
        chipBox.cornerRadius = 11
        chipBox.fillColor = .clear
        chipBox.contentViewMargins = .zero
        chipBox.contentView?.addSubview(chipLabel)

        [backButton, titleLabel, summaryLabel, chipBox, bodyView].forEach(addSubview)
        if let badge { addSubview(badge) }
        setChip(chip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setChip(_ chip: Chip?) {
        chipBox.isHidden = chip == nil
        if let chip {
            let color = chip.tone == .live ? SettingsTheme.teal : SettingsTheme.mutedText
            chipLabel.attributedStringValue = NSAttributedString(string: chip.text.uppercased(), attributes: [
                .kern: 1.6, .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: color,
            ])
            chipBox.borderColor = chip.tone == .live ? SettingsTheme.teal : SettingsTheme.line
        }
        needsLayout = true
    }

    /// Shows or clears the amber note above the page body.
    func setNotice(text: String?, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        noticeView?.removeFromSuperview()
        noticeView = nil
        if let text {
            let notice = SettingsNoticeView(text: text, actionTitle: actionTitle, action: action)
            addSubview(notice)
            noticeView = notice
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset = SettingsStyle.pageHorizontalInset
        let headerTop = bounds.height - SettingsStyle.pageTopInset
        let headerBottom = headerTop - SettingsStyle.pageHeaderHeight
        var x = inset
        if !backButton.isHidden {
            backButton.frame = NSRect(x: x, y: headerTop - 36, width: 84, height: 28)
            x += 84 + 14
        }
        if let badge {
            badge.frame = NSRect(x: x, y: headerTop - 47, width: 46, height: 46)
            x += 46 + 12
        }
        var chipWidth: CGFloat = 0
        if !chipBox.isHidden {
            chipWidth = ceil(chipLabel.fittingSize.width) + 22
            chipBox.frame = NSRect(x: bounds.width - inset - chipWidth, y: headerTop - 34,
                                   width: chipWidth, height: 22)
            chipLabel.frame = NSRect(x: 11, y: 3, width: chipWidth - 22, height: 15)
        }
        let textWidth = max(0, bounds.width - inset - x - chipWidth - 12)
        titleLabel.frame = NSRect(x: x, y: headerTop - 26, width: textWidth, height: 26)
        summaryLabel.frame = NSRect(x: x, y: headerTop - 45, width: textWidth, height: 18)

        var bodyTop = headerBottom - SettingsStyle.pageHeaderSpacing
        let bodyWidth = max(0, bounds.width - inset * 2)
        if let noticeView {
            let height = noticeView.preferredHeight(forWidth: bodyWidth)
            noticeView.frame = NSRect(x: inset, y: bodyTop - height, width: bodyWidth, height: height)
            bodyTop -= height + SettingsStyle.sectionSpacing
        }
        bodyView.frame = NSRect(
            x: inset, y: SettingsStyle.pageBottomInset,
            width: bodyWidth, height: max(0, bodyTop - SettingsStyle.pageBottomInset))
    }

    @objc private func back() {
        onBack?()
    }
}
