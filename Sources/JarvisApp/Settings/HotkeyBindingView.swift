import AppKit
import JarvisCore

/// Settings panel for the global manual-hint hotkey: one "click to record" control, plus an inline
/// callout when a user-chosen combination can't be registered (e.g. another app already owns it) —
/// see #229. A rejected rebind always leaves the previous, still-working combination live, so that
/// stays displayed and the failure is only flashed as immediate feedback on the attempt itself
/// (`recorded(_:)`); it does not persist across a page revisit, since the previous shortcut is still
/// fine. The one case that *is* persistent — the shipped default itself colliding with another app at
/// launch, so nothing is registered at all — keeps showing the callout on every revisit instead of
/// going quiet on a stale success.
@MainActor
final class HotkeyBindingView: NSObject {

    private let preferences: HotkeyPreferences
    private let boxEnabled: () -> Bool
    private var shortcutRow: SettingsRowView?
    private var cardHeightConstraint: NSLayoutConstraint?

    /// Show code and Explain more both answer into the detail box, so the Overlay Box switch is the
    /// one thing that decides whether they can be bound at all. The hint shortcut is unconditional.
    private var isEnabled: Bool { preferences.shortcut == .hint || boxEnabled() }
    private static let shortcutDetail = "Use ⌘ or ⌥ in the combination."
    private var cardHeight: CGFloat {
        SettingsStyle.cardHeaderHeight + SettingsStyle.rowHeight
    }
    /// Whether the controller currently has *any* combination registered. This is the only thing
    /// that must persist across Settings visits: a rejected rebind always leaves the previous,
    /// still-working combination live (see `HotkeyController.apply`), so the sole way this is false
    /// is the shipped default itself colliding with another app at launch — nothing was ever
    /// registered this run. Both branches of `renderOutcome` read this: it decides whether a
    /// revisit shows the persistent-failure callout, and it picks that callout's wording.
    private let hasActiveHotkey: () -> Bool
    /// Attempts to register a candidate combination and reports whether it took. Persisting the
    /// choice is this section's job, only after a `.registered` outcome — see `recorded(_:)`.
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
            // The controller left the previous, still-working combination registered — reflect that,
            // not the rejected candidate, and never persist a combination that isn't actually live.
            recorder?.setCombination(preferences.combination)
        }
        renderOutcome(outcome)
    }

    /// `outcome` is the immediate result of one `recorded(_:)` attempt — pass it right after a
    /// rebind to flash honest feedback about *that* attempt. Passing nothing (`makeView()` opening
    /// the page, `didBecomeActive()` revisiting it) must not replay that transient result: a rejected
    /// rebind whose previous combination is still active is not an ongoing problem, so on a revisit
    /// the callout shows only for the one state that *is* persistent — nothing registered at all.
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

    /// What the shortcut does, in the card header.
    private static func summary(of shortcut: CoachingShortcut) -> String {
        switch shortcut {
        case .hint: "I look at your screen and the conversation, then answer now."
        case .explainMore: "I go deeper on the last hint in the Overlay Box."
        case .showCode: "I write the code for the current step in the Overlay Box."
        }
    }
}
