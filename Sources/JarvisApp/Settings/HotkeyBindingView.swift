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
    private static let shortcutDetail = "Use ⌘ or ⌥ in the combination."
    private var cardHeight: CGFloat {
        SettingsStyle.cardHeaderHeight + SettingsStyle.rowHeight
    }
    /// False only when nothing was registered this run, because a rejected rebind keeps the
    /// previous combination live.
    private let hasActiveHotkey: () -> Bool
    private let applyCombination: (HotkeyCombination) -> HotkeyRegistrationOutcome

    private var recorder: HotkeyRecorderButton?
    private var callout: SettingsCalloutView?
    private var calloutHeightConstraint: NSLayoutConstraint?

    private static let calloutHeight = SettingsCalloutView.preferredHeight
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
                       detail: Self.summary(of: preferences.shortcut))
        let row = SettingsRowView(
            title: "Shortcut",
            detail: Self.shortcutDetail,
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

        let callout = SettingsCalloutView(text: "", tone: .warning)
        callout.isHidden = true
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
            ? Self.shortcutDetail
            : "Needs the Overlay Box. Switch it on in Mouth.")
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
        callout?.setText(hasActiveHotkey()
            ? "That shortcut is already in use. Your previous shortcut is unchanged."
            : "That shortcut is already in use, and this shortcut is not "
                + "currently active.")
        calloutHeightConstraint?.constant = Self.calloutHeight
        callout?.isHidden = false
    }

    private static func summary(of shortcut: CoachingShortcut) -> String {
        switch shortcut {
        case .hint: "I look at your screen and the conversation, then answer now."
        case .explainMore: "I go deeper on the last hint in the Overlay Box."
        case .showCode: "I write the code for the current step in the Overlay Box."
        }
    }
}
