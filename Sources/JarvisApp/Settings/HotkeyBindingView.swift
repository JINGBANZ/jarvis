import AppKit
import JarvisCore

@MainActor
final class HotkeyBindingView: NSObject {

    private let preferences: HotkeyPreferences
    private let boxEnabled: () -> Bool
    private var shortcutRow: SettingsRowView?
    private var cardHeightConstraint: NSLayoutConstraint?

    /// Non-hint shortcuts answer into the detail box, so they need the Overlay Box switched on.
    private var isEnabled: Bool { preferences.shortcut == .hint || boxEnabled() }
    private var cardHeight: CGFloat {
        SettingsStyle.cardHeaderHeight + SettingsStyle.rowHeight
    }
    /// False only when nothing was registered this run, because a rejected rebind keeps the
    /// previous combination live.
    private let hasActiveHotkey: () -> Bool
    private let applyCombination: (HotkeyCombination) -> HotkeyRegistrationOutcome

    private var recorder: HotkeyRecorderButton?
    private var callout: NSBox?
    private var calloutLabel: NSTextField?
    private var calloutHeightConstraint: NSLayoutConstraint?

    private static let calloutHeight: CGFloat = 60
    var onHeightChanged: (() -> Void)?
    var preferredHeight: CGFloat {
        cardHeight + SettingsStyle.sectionSpacing
            + (calloutHeightConstraint?.constant ?? 0)
    }

    init(
        preferences: HotkeyPreferences,
        boxEnabled: @escaping () -> Bool = { true },
        hasActiveHotkey: @escaping () -> Bool,
        applyCombination: @escaping (HotkeyCombination) -> HotkeyRegistrationOutcome
    ) {
        self.boxEnabled = boxEnabled
        self.preferences = preferences
        self.hasActiveHotkey = hasActiveHotkey
        self.applyCombination = applyCombination
    }

    func makeView() -> NSView {
        let body = NSView(frame: NSRect(x: 0, y: 0, width: 712, height: 180))

        let recorder = HotkeyRecorderButton(combination: preferences.combination)
        recorder.setAccessibilityLabel("\(preferences.shortcut.title) shortcut")
        recorder.onRecorded = { [weak self] combination in
            self?.recorded(combination)
        }
        self.recorder = recorder

        let card = SettingsCardView(frame: NSRect(x: 0, y: 0, width: 712, height: cardHeight))
        card.translatesAutoresizingMaskIntoConstraints = false
        card.setHeader(title: preferences.shortcut.title,
                       detail: "Works only while a session is running")
        let row = SettingsRowView(
            title: "Shortcut",
            detail: "Requires ⌘ or ⌥",
            controlView: recorder,
            controlSize: NSSize(width: 170, height: 32),
            preferredHeight: SettingsStyle.rowHeight,
            showsSeparator: false)
        shortcutRow = row
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
            callout.topAnchor.constraint(equalTo: card.bottomAnchor, constant: SettingsStyle.sectionSpacing),
            callout.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            callout.trailingAnchor.constraint(equalTo: body.trailingAnchor),
        ])
        let height = card.heightAnchor.constraint(equalToConstant: cardHeight)
        height.isActive = true
        cardHeightConstraint = height
        let calloutHeight = callout.heightAnchor.constraint(equalToConstant: 0)
        calloutHeight.isActive = true
        calloutHeightConstraint = calloutHeight

        renderOutcome()

        body.translatesAutoresizingMaskIntoConstraints = false
        body.bottomAnchor.constraint(equalTo: callout.bottomAnchor).isActive = true
        return body
    }

    func didBecomeActive() {
        recorder?.setCombination(preferences.combination)
        renderOutcome()
    }

    private func recorded(_ combination: HotkeyCombination) {
        guard isEnabled else { return }
        let outcome = applyCombination(combination)
        switch outcome {
        case .registered:
            preferences.combination = combination
            recorder?.setCombination(combination)
        case .failed:
            // The previous combination is still registered, so show it and never persist the
            // rejected one.
            recorder?.setCombination(preferences.combination)
        }
        renderOutcome(outcome)
    }

    /// Pass a fresh rebind's `outcome` to flash feedback for that attempt. With `nil` (open or
    /// revisit), the callout shows only when nothing is registered at all.
    private func renderOutcome(_ outcome: HotkeyRegistrationOutcome? = nil) {
        defer { onHeightChanged?() }
        recorder?.isEnabled = isEnabled
        cardHeightConstraint?.constant = cardHeight
        shortcutRow?.setDetail(isEnabled
            ? "Requires ⌘ or ⌥"
            : "Requires Overlay Box · enable it in Overlay settings")
        let showsFailure: Bool
        switch outcome {
        case .registered: showsFailure = false
        case .failed: showsFailure = true
        case nil: showsFailure = !hasActiveHotkey()
        }
        guard isEnabled && showsFailure else {
            calloutHeightConstraint?.constant = 0
            callout?.isHidden = true
            return
        }
        calloutLabel?.stringValue = hasActiveHotkey()
            ? "That shortcut is already in use. Your previous shortcut is unchanged."
            : "That shortcut is already in use, and this shortcut is not "
                + "currently active."
        calloutHeightConstraint?.constant = Self.calloutHeight
        callout?.isHidden = false
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
