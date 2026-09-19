import AppKit
import JarvisCore

@MainActor
final class MouseHotkeyController {
    var onRequest: ((CoachingShortcut) -> Void)?
    var isEnabled: (CoachingShortcut) -> Bool = { _ in false }
    var isRecording = false {
        didSet { updateTapEnabled() }
    }

    private var router = MouseShortcutRouter()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init(preferences: [HotkeyPreferences]) {
        for preference in preferences {
            if !router.bind(preference.mouseCombination, to: preference.shortcut) {
                jlog("Jarvis: duplicate or invalid saved mouse shortcut for \(preference.shortcut.title).")
            }
        }
        if !router.bindings.isEmpty { _ = prepare() }
    }

    func hasBinding(for shortcut: CoachingShortcut) -> Bool {
        guard let tap else { return false }
        return BrowserAccessibilityPermission.isGranted
            && CGEvent.tapIsEnabled(tap: tap) && router.bindings[shortcut] != nil
    }

    func apply(_ combination: MouseHotkeyCombination?, for shortcut: CoachingShortcut) -> String? {
        var candidate = router
        guard candidate.bind(combination, to: shortcut) else {
            return "That mouse shortcut is already in use or isn't supported."
        }
        if combination != nil, let failure = prepare() { return failure }
        router = candidate
        updateTapEnabled()
        return nil
    }

    func prepare() -> String? {
        guard BrowserAccessibilityPermission.isGranted else {
            return "Enable Jarvis in System Settings → Privacy & Security → Accessibility, then record again."
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            return CGEvent.tapIsEnabled(tap: tap) ? nil : "Mouse shortcuts are unavailable. Try recording again."
        }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                    .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                    .otherMouseDown, .otherMouseUp, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<MouseHotkeyController>.fromOpaque(context).takeUnretainedValue()
                // The tap source is installed only on the main run loop.
                let consumed = MainActor.assumeIsolated { controller.handle(type, event: event) == nil }
                return consumed ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()), // AppDelegate retains self for the app lifetime.
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return "Couldn't enable mouse shortcuts. Check Accessibility permission and try again."
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return nil
    }

    private func updateTapEnabled() {
        guard let tap else { return }
        let enabled = (isRecording || router.needsMouseEvents) && BrowserAccessibilityPermission.isGranted
        if CGEvent.tapIsEnabled(tap: tap) != enabled {
            CGEvent.tapEnable(tap: tap, enable: enabled)
        }
    }

    private func handle(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            router.resetPressedButtons()
            updateTapEnabled()
            return Unmanaged.passUnretained(event)
        }
        let phase: MouseShortcutRouter.Phase
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: phase = .down
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: phase = .up
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: phase = .drag
        default: return Unmanaged.passUnretained(event)
        }
        var modifiers: HotkeyModifiers = []
        if event.flags.contains(.maskCommand) { modifiers.insert(.command) }
        if event.flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if event.flags.contains(.maskControl) { modifiers.insert(.control) }
        if event.flags.contains(.maskShift) { modifiers.insert(.shift) }
        let enabled = isRecording ? [] : Set(CoachingShortcut.allCases.filter(isEnabled))
        let outcome = router.handle(
            button: Int(event.getIntegerValueField(.mouseEventButtonNumber)),
            modifiers: modifiers, phase: phase, enabled: enabled)
        if phase == .up { updateTapEnabled() }
        switch outcome {
        case .passThrough: return Unmanaged.passUnretained(event)
        case .consume: return nil
        case .trigger(let shortcut):
            // Keep the event-tap callback short; coaching and overlay work runs after it returns.
            Task { @MainActor [weak self] in
                guard let self, !self.isRecording, self.isEnabled(shortcut) else { return }
                self.onRequest?(shortcut)
            }
            return nil
        }
    }
}
