import AppKit
import JarvisCore

@MainActor
final class HotkeyBindingView: NSObject {
    private let preferences: HotkeyPreferences
    private let boxEnabled: () -> Bool
    /// False only when nothing was registered this run, because a rejected rebind keeps the
    /// previous combination live.
    private let hasActiveHotkey: () -> Bool
    private let applyCombination: (HotkeyCombination) -> HotkeyRegistrationOutcome

    private var row: SettingsRowView?
    private var keycaps: ShortcutKeycapsView?
    private var recorder: HotkeyRecorderButton?
    /// A rejected rebind's warning stays until the page is revisited.
    private var lastOutcome: HotkeyRegistrationOutcome?
    private var isRecording = false

    /// Non-hint shortcuts answer into the detail box, so they need the Overlay Box switched on.
    private var isEnabled: Bool { preferences.shortcut == .hint || boxEnabled() }

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

    func makeRow(showsSeparator: Bool) -> SettingsRowView {
        let title = preferences.shortcut.title
        let keycaps = ShortcutKeycapsView(frame: .zero)
        keycaps.keys = HotkeyKeyNames.keyCaps(for: preferences.combination)
        keycaps.setAccessibilityLabel("\(title) shortcut")
        let recorder = HotkeyRecorderButton()
        recorder.setAccessibilityLabel("Record \(title) shortcut")
        recorder.onRecorded = { [weak self] combination in self?.recorded(combination) }
        recorder.onRecordingChanged = { [weak self] recording in
            self?.isRecording = recording
            self?.render()
        }
        self.keycaps = keycaps
        self.recorder = recorder

        let controls = NSStackView(views: [keycaps, recorder])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 10
        keycaps.setContentHuggingPriority(.required, for: .horizontal)
        recorder.setContentHuggingPriority(.required, for: .horizontal)
        let container = NSView()
        controls.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            controls.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        let row = SettingsRowView(
            title: title,
            detail: "",
            controlView: container,
            controlSize: NSSize(width: 240, height: 32),
            showsSeparator: showsSeparator)
        self.row = row
        lastOutcome = nil
        render()
        return row
    }

    func didBecomeActive() {
        recorder?.stopRecording()
        lastOutcome = nil
        render()
    }

    private func recorded(_ combination: HotkeyCombination) {
        guard isEnabled else { return }
        let outcome = applyCombination(combination)
        if case .registered = outcome {
            preferences.combination = combination
        }
        lastOutcome = outcome
        render()
    }

    private func render() {
        keycaps?.keys = HotkeyKeyNames.keyCaps(for: preferences.combination)
        recorder?.isEnabled = isEnabled
        keycaps?.alphaValue = isEnabled ? 1 : 0.45
        guard isEnabled else {
            row?.setDetail("Needs the Overlay Box. Switch it on in Mouth.")
            return
        }
        if isRecording {
            row?.setDetail("Press the new shortcut with ⌘ or ⌥. Esc cancels.", color: SettingsTheme.teal)
            return
        }
        let showsFailure: Bool
        switch lastOutcome {
        case .registered: showsFailure = false
        case .failed: showsFailure = true
        case nil: showsFailure = !hasActiveHotkey()
        }
        if showsFailure {
            row?.setDetail(hasActiveHotkey()
                ? "That shortcut is already in use. Your previous shortcut still works."
                : "That shortcut is already in use, so this one isn't active.",
                color: SettingsTheme.amber)
        } else {
            row?.setDetail(Self.summary(of: preferences.shortcut))
        }
    }

    private static func summary(of shortcut: CoachingShortcut) -> String {
        switch shortcut {
        case .hint: "I look at your screen and the conversation, then answer now."
        case .explainMore: "I go deeper on the last hint in the Overlay Box."
        case .showCode: "I write the code for the current step in the Overlay Box."
        }
    }
}
