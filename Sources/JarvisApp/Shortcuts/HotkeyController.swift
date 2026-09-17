import AppKit
import Carbon.HIToolbox
import JarvisCore

/// Carbon hot keys need no Accessibility grant, and the SwiftUI-macro wrapper packages don't build
/// with the Command Line Tools.
@MainActor
final class HotkeyController {
    var onRequest: ((CoachingShortcut) -> Void)?

    private var hotKeyRefs: [CoachingShortcut: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    /// What Carbon holds now, which can differ from the saved preference after a failed rebind.
    private(set) var registered: [CoachingShortcut: HotkeyCombination] = [:]

    /// 'JRVS', so our hot-key IDs can't collide with another component's.
    private static let signature: OSType = 0x4A_52_56_53

    init(preferences: [HotkeyPreferences]) {
        installHandler()
        for preference in preferences { register(preference.combination, for: preference.shortcut) }
    }

    // No teardown: this lives for the app run, and the OS reclaims hot keys on exit.

    /// Registers the new key before releasing the old, so a rejected one leaves the old key live.
    @discardableResult
    func apply(_ combination: HotkeyCombination, for shortcut: CoachingShortcut) -> HotkeyRegistrationOutcome {
        // Carbon rejects re-registering a combination this process still holds.
        guard combination != registered[shortcut] else { return .registered }
        let previousRef = hotKeyRefs[shortcut]
        let outcome = register(combination, for: shortcut)
        if case .registered = outcome, let previousRef {
            let status = UnregisterEventHotKey(previousRef)
            if status != noErr {
                jlog("Jarvis: coaching shortcut failed to release the previous binding after rebinding "
                     + "(status \(status)).")
            }
        }
        return outcome
    }

    func unregister(_ shortcut: CoachingShortcut) {
        guard let ref = hotKeyRefs[shortcut] else { return }
        let status = UnregisterEventHotKey(ref)
        guard status == noErr else {
            jlog("Jarvis: failed to release disabled shortcut (status \(status)).")
            return
        }
        hotKeyRefs.removeValue(forKey: shortcut)
        registered.removeValue(forKey: shortcut)
    }

    /// The C callback can't capture context, so `self` travels through `userData`.
    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == HotkeyController.signature,
                  let shortcut = CoachingShortcut(rawValue: identifier.id) else {
                return OSStatus(eventNotHandledErr)
            }
            let controller = Unmanaged<HotkeyController>.fromOpaque(userData).takeUnretainedValue()
            // Carbon delivers application-target hot-key events on the main thread.
            MainActor.assumeIsolated {
                guard controller.registered[shortcut] != nil else { return }
                controller.onRequest?(shortcut)
            }
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)
        if status != noErr { jlog("Jarvis: hint-hotkey handler install failed (status \(status)).") }
    }

    @discardableResult
    private func register(_ combination: HotkeyCombination, for shortcut: CoachingShortcut) -> HotkeyRegistrationOutcome {
        let id = EventHotKeyID(signature: Self.signature, id: shortcut.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combination.keyCode, combination.modifiers.rawValue, id,
            GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            jlog("Jarvis: coaching shortcut \(HotkeyKeyNames.displayString(for: combination)) unavailable "
                 + "(status \(status)) — another app may already own it.")
            return .failed(status: status)
        }
        hotKeyRefs[shortcut] = ref
        registered[shortcut] = combination
        return .registered
    }
}
