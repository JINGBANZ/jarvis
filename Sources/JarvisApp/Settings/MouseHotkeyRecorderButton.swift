import AppKit
import JarvisCore

@MainActor
final class MouseHotkeyRecorderButton: NSButton {
    var onRecorded: ((MouseHotkeyCombination) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    var prepare: (() -> Bool)?
    private var monitor: Any?
    private var candidate: MouseHotkeyCombination?
    private var isRecording = false

    init() {
        super.init(frame: .zero)
        title = "Record"
        bezelStyle = .rounded
        target = self
        action = #selector(startRecording)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        stopRecording()
        super.viewWillMove(toWindow: newWindow)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { stopRecording() }
    }

    @objc func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        candidate = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard isRecording else { return }
        isRecording = false
        title = "Record"
        onRecordingChanged?(false)
    }

    @objc private func startRecording() {
        if isRecording { stopRecording(); return }
        guard window?.makeFirstResponder(self) == true, prepare?() != false else { return }
        isRecording = true
        title = "Click mouse…"
        onRecordingChanged?(true)
        NotificationCenter.default.addObserver(self, selector: #selector(stopRecording),
            name: NSWindow.didResignKeyNotification, object: window)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseUp, .rightMouseUp, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]) { [weak self] event in
            guard let self else { return event }
            // AppKit invokes local event monitors on the main thread.
            let consumed = MainActor.assumeIsolated { self.record(event) == nil }
            return consumed ? nil : event
        }
    }

    private func record(_ event: NSEvent) -> NSEvent? {
        guard isRecording else { return event }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let combination = MouseHotkeyCombination(
                button: event.buttonNumber, modifiers: event.modifierFlags.hotkeyModifiers)
            guard combination.isValid else {
                stopRecording()
                return event
            }
            candidate = combination
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if let candidate, candidate.button == event.buttonNumber {
                stopRecording()
                onRecorded?(candidate)
                return nil
            }
            return event
        default:
            return candidate?.button == event.buttonNumber ? nil : event
        }
        return nil
    }
}
