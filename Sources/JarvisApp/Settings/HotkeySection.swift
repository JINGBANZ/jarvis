import AppKit
import JarvisCore

/// Settings panel for the global manual-hint hotkey: one "click to record" control, plus an inline
/// callout when a user-chosen combination can't be registered (e.g. another app already owns it) —
/// see #229. A rejected rebind always leaves the previous, still-working combination live, so that
/// stays displayed and only the failure is new information; the one case where nothing is actually
/// registered is the shipped default itself colliding with another app at launch, and the callout says
/// so instead of falsely claiming an old shortcut is still active.
@MainActor
final class HotkeySection: NSObject, SettingsSection {
    let title = "Shortcuts"
    let fillsTab = true

    private let preferences: HotkeyPreferences
    /// Reads the controller's live registration outcome — used on `didBecomeActive` so a failure that
    /// happened before Settings was ever opened (e.g. at launch, for a previously-rebound
    /// combination) is still surfaced.
    private let currentOutcome: () -> HotkeyRegistrationOutcome
    /// Whether the controller currently has *any* combination registered. A rejected rebind always
    /// leaves the previous, still-working combination live (see `HotkeyController.apply`), so the only
    /// way this is false is the shipped default itself colliding with another app at launch — nothing
    /// was ever registered this run. `currentOutcome` alone can't distinguish that case from "the
    /// previous combination stays active," so the failure callout reads this too.
    private let hasActiveHotkey: () -> Bool
    /// Attempts to register a candidate combination and reports whether it took. Persisting the
    /// choice is this section's job, only after a `.registered` outcome — see `recorded(_:)`.
    private let applyCombination: (HotkeyCombination) -> HotkeyRegistrationOutcome

    private var recorder: HotkeyRecorderButton?
    private var callout: NSBox?
    private var calloutLabel: NSTextField?
    private var calloutHeightConstraint: NSLayoutConstraint?

    private static let calloutHeight: CGFloat = 60

    init(
        preferences: HotkeyPreferences,
        currentOutcome: @escaping () -> HotkeyRegistrationOutcome,
        hasActiveHotkey: @escaping () -> Bool,
        applyCombination: @escaping (HotkeyCombination) -> HotkeyRegistrationOutcome
    ) {
        self.preferences = preferences
        self.currentOutcome = currentOutcome
        self.hasActiveHotkey = hasActiveHotkey
        self.applyCombination = applyCombination
    }

    func makeView() -> NSView {
        let body = NSView(frame: NSRect(x: 0, y: 0, width: 712, height: 432))

        let recorder = HotkeyRecorderButton(combination: preferences.combination)
        recorder.onRecorded = { [weak self] combination in
            self?.recorded(combination)
        }
        self.recorder = recorder

        let cardHeight = SettingsStyle.cardHeaderHeight + SettingsStyle.rowHeight
        let card = SettingsCardView(frame: NSRect(x: 0, y: 0, width: 712, height: cardHeight))
        card.translatesAutoresizingMaskIntoConstraints = false
        card.setHeader(title: "Manual hint", detail: "Works only while a session is running")
        let row = SettingsRowView(
            title: "Shortcut",
            detail: "Requires ⌘, ⌥, or ⌃ — Shift alone isn't enough",
            controlView: recorder,
            controlSize: NSSize(width: 170, height: 32),
            preferredHeight: SettingsStyle.rowHeight,
            showsSeparator: false)
        card.contentView?.addSubview(row)
        card.onLayout = { [weak card, weak row] in
            guard let card, let row else { return }
            row.frame = card.bodyFrame
        }

        let callout = makeCallout()
        callout.translatesAutoresizingMaskIntoConstraints = false
        self.callout = callout

        body.addSubview(card)
        body.addSubview(callout)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: body.topAnchor),
            card.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            card.heightAnchor.constraint(equalToConstant: cardHeight),
            callout.topAnchor.constraint(equalTo: card.bottomAnchor, constant: SettingsStyle.sectionSpacing),
            callout.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            callout.trailingAnchor.constraint(equalTo: body.trailingAnchor),
        ])
        let calloutHeight = callout.heightAnchor.constraint(equalToConstant: 0)
        calloutHeight.isActive = true
        calloutHeightConstraint = calloutHeight

        renderOutcome()

        return SettingsPageView(
            title: "Shortcuts",
            summary: "Rebind the global shortcut that forces an immediate hint.",
            bodyView: body)
    }

    func didBecomeActive() {
        recorder?.setCombination(preferences.combination)
        renderOutcome()
    }

    private func recorded(_ combination: HotkeyCombination) {
        let outcome = applyCombination(combination)
        switch outcome {
        case .registered:
            preferences.combination = combination
            recorder?.setCombination(combination)
        case .failed:
            // The controller left the previous, still-working combination registered — reflect that,
            // not the rejected candidate, and never persist a combination that isn't actually live.
            recorder?.setCombination(preferences.combination)
        }
        renderOutcome(outcome)
    }

    private func renderOutcome(_ outcome: HotkeyRegistrationOutcome? = nil) {
        switch outcome ?? currentOutcome() {
        case .registered:
            calloutHeightConstraint?.constant = 0
            callout?.isHidden = true
        case .failed:
            calloutLabel?.stringValue = hasActiveHotkey()
                ? "That shortcut is already in use by another app. The previous shortcut stays active."
                : "That shortcut is already in use by another app, and no manual-hint shortcut is "
                    + "currently active."
            calloutHeightConstraint?.constant = Self.calloutHeight
            callout?.isHidden = false
        }
    }

    private func makeCallout() -> NSBox {
        let callout = NSBox()
        callout.boxType = .custom
        callout.borderWidth = 1
        callout.cornerRadius = 10
        callout.borderColor = NSColor.systemOrange.withAlphaComponent(0.25)
        callout.fillColor = NSColor.systemOrange.withAlphaComponent(0.08)
        callout.contentViewMargins = .zero
        callout.isHidden = true

        guard let content = callout.contentView else { return callout }
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        icon.contentTintColor = .systemOrange
        content.addSubview(icon)

        let label = NSTextField(wrappingLabelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        content.addSubview(label)
        calloutLabel = label

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        return callout
    }
}
