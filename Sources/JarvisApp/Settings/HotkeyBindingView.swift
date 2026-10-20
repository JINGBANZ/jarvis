import AppKit
import JarvisCore

@MainActor
final class HotkeyBindingView: NSObject {
    private let preferences: HotkeyPreferences
    /// False only when nothing was registered this run, because a rejected rebind keeps the
    /// previous combination live.
    private let hasActiveHotkey: () -> Bool
    private let applyCombination: (HotkeyCombination) -> HotkeyRegistrationOutcome

    private var row: ShortcutSettingsRowView?
    private var recorder: HotkeyRecorderButton?
    /// A rejected rebind's warning stays until the page is revisited.
    private var lastOutcome: HotkeyRegistrationOutcome?
    private var isRecording = false

    init(
        preferences: HotkeyPreferences,
        hasActiveHotkey: @escaping () -> Bool,
        applyCombination: @escaping (HotkeyCombination) -> HotkeyRegistrationOutcome
    ) {
        self.preferences = preferences
        self.hasActiveHotkey = hasActiveHotkey
        self.applyCombination = applyCombination
    }

    func makeRow(mouseBinding: MouseHotkeyBindingView, showsSeparator: Bool) -> ShortcutSettingsRowView {
        let title = preferences.shortcut.title
        let recorder = HotkeyRecorderButton()
        recorder.setAccessibilityLabel("Record \(title) shortcut")
        recorder.onRecorded = { [weak self] combination in self?.recorded(combination) }
        recorder.onRecordingChanged = { [weak self] recording in
            self?.isRecording = recording
            self?.render()
        }
        self.recorder = recorder
        let row = ShortcutSettingsRowView(
            title: title, keyboard: recorder, mouse: mouseBinding.makeControl(),
            showsSeparator: showsSeparator)
        mouseBinding.onNotice = { [weak row] text, color in row?.setMouseNotice(text, color: color) }
        mouseBinding.refresh()
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
        let outcome = applyCombination(combination)
        if case .registered = outcome {
            preferences.combination = combination
        }
        lastOutcome = outcome
        render()
    }

    private func render() {
        let combination = HotkeyKeyNames.displayString(for: preferences.combination)
        recorder?.setAccessibilityValue(combination)
        recorder?.setAccessibilityHelp(isRecording
            ? "Current shortcut: \(combination). Press the new shortcut with ⌘ or ⌥. Esc cancels."
            : "Current shortcut: \(combination). Activate to record a new shortcut.")
        if isRecording {
            row?.setDetail("Press the new shortcut with ⌘ or ⌥. Esc cancels.", color: SettingsTheme.teal,
                           prioritizesKeyboard: true)
            return
        }
        recorder?.title = HotkeyKeyNames.keyCaps(for: preferences.combination).joined(separator: " ")
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
                color: SettingsTheme.amber, prioritizesKeyboard: true)
        } else {
            row?.setDetail(Self.summary(of: preferences.shortcut))
        }
    }

    private static func summary(of shortcut: CoachingShortcut) -> String {
        switch shortcut {
        case .hint: "I look at your screen and the conversation, then answer now."
        case .explainMore: "I go deeper on the last hint in the Overlay Box."
        case .showCode: "I write the code for the current step in the Overlay Box."
        case .previousDetail: "I show my previous detail in the Overlay Box."
        case .nextDetail: "I show my next detail in the Overlay Box."
        }
    }
}
