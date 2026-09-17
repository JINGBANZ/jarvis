import AppKit
import Carbon.HIToolbox
import JarvisCore

@MainActor
final class HotkeyRecorderButton: NSButton {
    /// Reports a candidate only; the caller decides whether to persist it.
    var onRecorded: ((HotkeyCombination) -> Void)?

    private var isRecording = false
    private var displayedCombination: HotkeyCombination

    init(combination: HotkeyCombination) {
        displayedCombination = combination
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(startRecording)
        setAccessibilityLabel("Manual hint shortcut")
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setCombination(_ combination: HotkeyCombination) {
        displayedCombination = combination
        isRecording = false
        updateTitle()
    }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        if isRecording { cancelRecording() }
        return super.resignFirstResponder()
    }

    // AppKit offers Command key-downs to the menu as key equivalents before `keyDown`, so without
    // this, recording ⌘Q would quit the app.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        handleCandidateKeyEvent(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        handleCandidateKeyEvent(event)
    }

    private func handleCandidateKeyEvent(_ event: NSEvent) {
        guard event.keyCode != UInt16(kVK_Escape) else {
            cancelRecording()
            return
        }
        let modifiers = event.modifierFlags.hotkeyModifiers
        guard modifiers.satisfiesHotkeyRequirement else { return }
        let candidate = HotkeyCombination(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        isRecording = false
        displayedCombination = candidate
        updateTitle()
        onRecorded?(candidate)
    }

    @objc private func startRecording() {
        guard window?.makeFirstResponder(self) == true else { return }
        isRecording = true
        title = "Press shortcut…"
    }

    private func cancelRecording() {
        isRecording = false
        updateTitle()
    }

    private func updateTitle() {
        title = HotkeyKeyNames.displayString(for: displayedCombination)
    }
}
