import AppKit
import JarvisCore

/// The layout both steps share: Jarvis's head, a title and one line under it, the step's own body,
/// a note, and Quit, progress, and the primary button along the bottom.
@MainActor
final class OnboardingStepView: NSView {
    /// The whole window, title bar included: the layout is measured from the window's top edge.
    static let size = NSSize(width: 660, height: 560)

    private let primaryButton: ClosureButton
    private let noteLabel = NSTextField(wrappingLabelWithString: "")

    init(
        lit: Set<RobotPart>, title: String, lede: String, body: NSView,
        step index: Int, of count: Int,
        onQuit: @escaping () -> Void, onPrimary: @escaping () -> Void
    ) {
        primaryButton = ClosureButton(title: "", action: onPrimary)
        super.init(frame: NSRect(origin: .zero, size: Self.size))

        let head = RobotHeadView(style: .still(lit: lit))
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.textColor = OnboardingTheme.text
        titleLabel.alignment = .center
        let ledeLabel = NSTextField(wrappingLabelWithString: lede)
        ledeLabel.font = .systemFont(ofSize: 13)
        ledeLabel.textColor = OnboardingTheme.secondaryText
        ledeLabel.alignment = .center
        noteLabel.font = .systemFont(ofSize: 11.5)
        noteLabel.textColor = OnboardingTheme.tertiaryText
        noteLabel.maximumNumberOfLines = 2
        let quitButton = ClosureButton(title: "Quit", action: onQuit)
        for button in [quitButton, primaryButton] {
            button.bezelStyle = .rounded
            button.controlSize = .large
        }
        primaryButton.keyEquivalent = "\r"
        let progress = OnboardingProgressView(step: index, of: count)

        for view in [head, titleLabel, ledeLabel, body, noteLabel, quitButton, progress, primaryButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let inset: CGFloat = 40
        var constraints = [
            head.topAnchor.constraint(equalTo: topAnchor, constant: 34),
            head.centerXAnchor.constraint(equalTo: centerXAnchor),
            head.widthAnchor.constraint(equalToConstant: 70),
            head.heightAnchor.constraint(equalToConstant: 84),
            titleLabel.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 12),
            ledeLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            body.topAnchor.constraint(equalTo: ledeLabel.bottomAnchor, constant: 22),
            noteLabel.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 8),
            quitButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            quitButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            quitButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 84),
            primaryButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            primaryButton.centerYAnchor.constraint(equalTo: quitButton.centerYAnchor),
            primaryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            progress.centerXAnchor.constraint(equalTo: centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: quitButton.centerYAnchor),
        ]
        for view in [titleLabel, ledeLabel, body, noteLabel] {
            constraints.append(view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset))
            constraints.append(view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset))
        }
        NSLayoutConstraint.activate(constraints)
        // A wrapping label sizes its height from this width, not from its constraints.
        ledeLabel.preferredMaxLayoutWidth = Self.size.width - inset * 2
        noteLabel.preferredMaxLayoutWidth = Self.size.width - inset * 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setPrimary(title: String, enabled: Bool) {
        primaryButton.title = title
        primaryButton.isEnabled = enabled
    }

    func setNote(_ text: String, warning: Bool) {
        noteLabel.stringValue = text
        noteLabel.textColor = warning ? OnboardingTheme.amber : OnboardingTheme.tertiaryText
    }
}
