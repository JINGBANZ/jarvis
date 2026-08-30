import AppKit
import Carbon.HIToolbox
import JarvisCore

/// A "click to record" control for the manual-hint global hotkey: shows the current combination as a
/// button title; a click starts recording, and the next key + modifier(s) pressed becomes the
/// candidate. A bare key press (no modifier held) is ignored — one global hotkey app-wide must not be
/// a key someone types into a random text field. Escape cancels recording and restores the previous
/// display without calling `onRecorded`.
@MainActor
final class HotkeyRecorderButton: NSButton {
    /// Called with a candidate combination once a valid key + modifier(s) is pressed while recording.
    /// The caller (not this control) decides whether to persist it — see `HotkeySection`.
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

    /// Reflect a combination decided elsewhere (a confirmed save, or reverting after a failed
    /// registration) without re-entering recording mode.
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

    // AppKit resolves a Command-holding key-down as a *key equivalent* — offering it to the menu bar
    // (via `performKeyEquivalent`) before it would ever reach `keyDown`. Recording ⌘Q while this
    // control is first responder would otherwise quit the app instead of being captured, since
    // `MainMenu` binds Quit to exactly that combo. Intercepting here, while recording, keeps every
    // Command-holding candidate ours before the menu ever sees it.
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
        guard !modifiers.isEmpty else { return }   // ignore a bare key; keep waiting
        let candidate = HotkeyCombination(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        isRecording = false
        displayedCombination = candidate
        updateTitle()
        onRecorded?(candidate)
    }

    @objc private func startRecording() {
        isRecording = true
        title = "Press shortcut…"
        window?.makeFirstResponder(self)
    }

    private func cancelRecording() {
        isRecording = false
        updateTitle()
    }

    private func updateTitle() {
        title = HotkeyKeyNames.displayString(for: displayedCombination)
    }
}
