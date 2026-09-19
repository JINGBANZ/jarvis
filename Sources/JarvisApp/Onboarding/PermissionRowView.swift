import AppKit

/// One permission: a state dot, its name, why Jarvis needs it, and a functional status label.
@MainActor
final class PermissionRowView: NSView {
    enum Tone {
        case needed
        case asking
        case granted
        case refused
    }

    static let height: CGFloat = 54

    private let statusLabel = NSTextField(labelWithString: "")
    private let showsSeparator: Bool
    private var tone = Tone.needed

    init(name: String, purpose: String, showsSeparator: Bool) {
        self.showsSeparator = showsSeparator
        super.init(frame: NSRect(x: 0, y: 0, width: 580, height: Self.height))
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = OnboardingTheme.text
        let purposeLabel = NSTextField(labelWithString: purpose)
        purposeLabel.font = .systemFont(ofSize: 11.5)
        purposeLabel.textColor = OnboardingTheme.secondaryText
        purposeLabel.lineBreakMode = .byTruncatingTail
        purposeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.alignment = .right
        for label in [nameLabel, purposeLabel, statusLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 38),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            purposeLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            purposeLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            purposeLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: statusLabel.leadingAnchor, constant: -12),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    func render(status: String, tone: Tone) {
        self.tone = tone
        statusLabel.stringValue = status
        statusLabel.font = .systemFont(ofSize: 12, weight: tone == .asking ? .semibold : .regular)
        statusLabel.textColor = switch tone {
        case .granted: OnboardingTheme.tealText
        case .refused: OnboardingTheme.amber
        case .asking: OnboardingTheme.text
        case .needed: OnboardingTheme.secondaryText
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if showsSeparator {
            OnboardingTheme.lineSoft.setFill()
            NSRect(x: 16, y: bounds.maxY - 1, width: bounds.width - 16, height: 1).fill()
        }
        let dot = NSBezierPath(ovalIn: NSRect(x: 16.75, y: bounds.midY - 4.25, width: 8.5, height: 8.5))
        if tone == .granted {
            OnboardingTheme.teal.setFill()
            dot.fill()
        } else {
            (tone == .refused ? OnboardingTheme.amber : OnboardingTheme.tertiaryText).setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
        }
    }
}
