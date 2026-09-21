import AppKit
import JarvisCore

@MainActor
final class MouseHotkeyBindingView: NSObject {
    private let preferences: HotkeyPreferences
    private let controller: MouseHotkeyController
    private let boxEnabled: () -> Bool
    private var recorder: MouseHotkeyRecorderButton?
    private var clearButton: NSButton?
    private var label: NSTextField?
    private var row: SettingsRowView?
    private var failure: String?
    private var isRecording = false

    init(preferences: HotkeyPreferences, controller: MouseHotkeyController, boxEnabled: @escaping () -> Bool) {
        self.preferences = preferences
        self.controller = controller
        self.boxEnabled = boxEnabled
    }

    func makeRow() -> SettingsRowView {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.label = label
        let recorder = MouseHotkeyRecorderButton()
        recorder.setAccessibilityLabel("Record \(preferences.shortcut.title) mouse shortcut")
        recorder.prepare = { [weak self] in
            guard let self else { return false }
            self.failure = self.controller.prepare()
            self.render()
            return self.failure == nil
        }
        recorder.onRecordingChanged = { [weak self] recording in
            guard let self else { return }
            self.isRecording = recording
            self.controller.isRecording = recording
            self.render()
        }
        recorder.onRecorded = { [weak self] in self?.apply($0) }
        self.recorder = recorder
        let clear = NSButton(title: "Clear", target: self, action: #selector(clear))
        clear.bezelStyle = .rounded
        clear.setAccessibilityLabel("Clear \(preferences.shortcut.title) mouse shortcut")
        clearButton = clear
        let controls = NSStackView(views: [label, recorder, clear])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        recorder.setContentHuggingPriority(.required, for: .horizontal)
        clear.setContentHuggingPriority(.required, for: .horizontal)
        let row = SettingsRowView(title: "\(preferences.shortcut.title) · Mouse", detail: "",
            controlView: controls, controlSize: NSSize(width: 310, height: 32))
        self.row = row
        render()
        return row
    }

    func refresh() {
        recorder?.stopRecording()
        failure = nil
        render()
    }

    func stopRecording() { recorder?.stopRecording() }

    @objc private func clear() { apply(nil) }

    private func apply(_ combination: MouseHotkeyCombination?) {
        failure = controller.apply(combination, for: preferences.shortcut)
        if failure == nil { preferences.mouseCombination = combination }
        render()
    }

    private func render() {
        let enabled = preferences.shortcut == .hint || boxEnabled()
        recorder?.isEnabled = enabled
        clearButton?.isEnabled = preferences.mouseCombination != nil && !isRecording
        label?.stringValue = preferences.mouseCombination.map(HotkeyKeyNames.displayString(for:)) ?? "Not set"
        label?.toolTip = label?.stringValue
        if !enabled {
            row?.setDetail("Needs the Overlay Box. Switch it on in Mouth.")
        } else if isRecording {
            row?.setDetail("Click here; left/right needs ⌘ or ⌥. Esc cancels.", color: SettingsTheme.teal)
        } else if let failure {
            row?.setDetail(failure, color: SettingsTheme.amber)
        } else if preferences.mouseCombination != nil && !controller.hasBinding(for: preferences.shortcut) {
            row?.setDetail("Mouse shortcut inactive. Check Accessibility, then record again.", color: SettingsTheme.amber)
        } else {
            row?.setDetail("Optional mouse button, with or without modifiers.")
        }
    }
}
