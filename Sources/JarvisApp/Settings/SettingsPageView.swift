import AppKit
import JarvisCore

@MainActor
final class SettingsPageView: NSView {
    struct Chip: Equatable {
        enum Tone: Equatable { case neutral, live }
        let text: String
        let tone: Tone
        static func neutral(_ text: String) -> Chip { Chip(text: text, tone: .neutral) }
        static func live(_ text: String) -> Chip { Chip(text: text, tone: .live) }
    }

    /// `nil` hides the back button.
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
    private static let chipFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    private static let chipHeight: CGFloat = 22

    private let chipBox = NSBox()
    private let chipLabel = NSTextField(labelWithString: "")
    private var noticeView: SettingsNoticeView?
    private var noticeContent: (text: String, actionTitle: String?)?
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

        // The body comes first: AppKit offers a key equivalent to subviews in order, and the back
        // button's ⌘[ must not pre-empt a shortcut recorder inside the body.
        [bodyView, backButton, titleLabel, summaryLabel, chipBox].forEach(addSubview)
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
                .kern: 1.6, .font: Self.chipFont, .foregroundColor: color,
            ])
            chipBox.borderColor = chip.tone == .live ? SettingsTheme.teal : SettingsTheme.line
        }
        needsLayout = true
    }

    /// An unchanged note is kept, so its button keeps focus and VoiceOver doesn't read it again.
    func setNotice(text: String?, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        let content = text.map { (text: $0, actionTitle: actionTitle) }
        guard content?.text != noticeContent?.text || content?.actionTitle != noticeContent?.actionTitle
        else { return }
        noticeContent = content
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
                                   width: chipWidth, height: Self.chipHeight)
            // A label draws from the top of its frame, and all-capitals text has no descenders, so a
            // centered label would sit the capitals high. Center the capitals themselves.
            let font = Self.chipFont
            // Not the box's content view: it keeps a stale size until the box lays itself out, and a
            // page laid out only once would keep the wrong position.
            let contentHeight = Self.chipHeight - 2 * chipBox.borderWidth
            let labelHeight = ceil(chipLabel.fittingSize.height)
            let capsBottom = (contentHeight - font.capHeight) / 2
            chipLabel.frame = NSRect(
                x: 11, y: ((capsBottom + font.ascender - labelHeight) * 2).rounded() / 2,
                width: chipWidth - 22, height: labelHeight)
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
