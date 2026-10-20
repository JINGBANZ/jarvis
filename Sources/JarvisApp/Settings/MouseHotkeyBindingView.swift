import AppKit
import JarvisCore

@MainActor
final class MouseHotkeyBindingView: NSObject {
    private let preferences: HotkeyPreferences
    private let controller: MouseHotkeyController
    private var recorder: MouseHotkeyRecorderButton?
    private var clearButton: NSButton?
    var onNotice: ((String?, NSColor?) -> Void)?
    private var failure: String?
    private var isRecording = false

    init(preferences: HotkeyPreferences, controller: MouseHotkeyController) {
        self.preferences = preferences
        self.controller = controller
    }

    func makeControl() -> NSView {
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
        let clear = NSButton(title: "×", target: self, action: #selector(clear))
        clear.bezelStyle = .rounded
        clear.setAccessibilityLabel("Clear \(preferences.shortcut.title) mouse shortcut")
        clearButton = clear
        let controls = NSStackView(views: [recorder, clear])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 4
        recorder.lineBreakMode = .byTruncatingMiddle
        recorder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        clear.setContentHuggingPriority(.required, for: .horizontal)
        let container = NSView()
        controls.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            controls.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            controls.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        render()
        return container
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
        clearButton?.isEnabled = preferences.mouseCombination != nil && !isRecording
        clearButton?.isHidden = preferences.mouseCombination == nil
        if !isRecording {
            recorder?.title = preferences.mouseCombination.map(HotkeyKeyNames.displayString(for:)) ?? "Not set +"
        }
        recorder?.setAccessibilityHelp(preferences.mouseCombination.map(HotkeyKeyNames.displayString(for:))
            ?? "Optional mouse button, with or without modifiers.")
        if isRecording {
            onNotice?("Click here; left/right needs ⌘ or ⌥. Esc cancels.", SettingsTheme.teal)
        } else if let failure {
            onNotice?(failure, SettingsTheme.amber)
        } else if preferences.mouseCombination != nil && !controller.hasBinding(for: preferences.shortcut) {
            onNotice?("Mouse shortcut inactive. Check Accessibility, then record again.", SettingsTheme.amber)
        } else {
            onNotice?(nil, nil)
        }
    }
}
