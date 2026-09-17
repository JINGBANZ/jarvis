import AppKit
import Carbon.HIToolbox
import JarvisCore

@MainActor
final class HotkeyRecorderButton: NSButton {
    /// Reports a candidate only; the caller decides whether to persist it.
    var onRecorded: ((HotkeyCombination) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?

    private var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            title = isRecording ? "Press keys…" : "Record"
            onRecordingChanged?(isRecording)
        }
    }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        title = "Record"
        target = self
        action = #selector(startRecording)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func stopRecording() {
        isRecording = false
    }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        isRecording = false
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
            isRecording = false
            return
        }
        let modifiers = event.modifierFlags.hotkeyModifiers
        guard modifiers.satisfiesHotkeyRequirement else { return }
        isRecording = false
        onRecorded?(HotkeyCombination(keyCode: UInt32(event.keyCode), modifiers: modifiers))
    }

    @objc private func startRecording() {
        guard window?.makeFirstResponder(self) == true else { return }
        isRecording = true
    }
}
