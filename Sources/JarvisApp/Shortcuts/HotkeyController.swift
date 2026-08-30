import AppKit
import Carbon.HIToolbox
import JarvisCore   // jlog, HotkeyPreferences, HotkeyCombination

/// Whether the most recent registration attempt for the currently-active combination succeeded.
/// Read by Settings to decide when a registration failure needs to be shown — only for a value the
/// user explicitly picked, never for the shipped default nobody chose.
enum HotkeyRegistrationOutcome: Equatable {
    case registered
    case failed(status: OSStatus)
}

/// Registers the single global hint hotkey via Carbon's `RegisterEventHotKey` and forwards each press
/// to `onRequestHint`. The shortcut is system-wide (it fires even when Jarvis, a menu-bar accessory,
/// isn't frontmost) and needs no Accessibility permission or permission dialog.
///
/// Carbon's hot-key API is the one global-shortcut mechanism Apple never gave a modern replacement,
/// and unlike the SwiftUI-macro-based wrapper packages it builds cleanly with the Command Line Tools
/// (no Xcode-only macro plugins). The binding is user-configurable via `HotkeyPreferences`/Settings
/// (see `HotkeySection`); this type only knows how to (re)register whatever combination it's given.
///
/// This type is intentionally thin: it knows nothing about sessions or the coach. `AppDelegate` owns
/// the policy (ignore-when-stopped, route through the turn box) via the callback.
@MainActor
final class HotkeyController {
    /// Called on the main actor each time the hint hotkey fires.
    var onRequestHint: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    /// The combination actually registered right now — nil only if nothing has registered
    /// successfully yet this run. Kept separate from `HotkeyPreferences.combination` so a failed
    /// rebind attempt can restore this exact still-active value.
    private(set) var registered: HotkeyCombination?
    private(set) var lastOutcome: HotkeyRegistrationOutcome = .failed(status: noErr)

    /// 'JRVS' — a unique signature so our hot-key id can't be confused with another component's.
    private static let signature: OSType = 0x4A_52_56_53

    init(preferences: HotkeyPreferences) {
        installHandler()
        lastOutcome = register(preferences.combination)
    }

    // No teardown: the controller lives for the whole app run (like the menu bar and overlay), and
    // the OS reclaims the registration on process exit. The refs are retained so the hot key and its
    // handler stay alive for the app's lifetime.

    /// Register `combination` in place of whatever is currently active. Registers the *new* Carbon key
    /// first and only releases the previous one once that succeeds, so a rejected candidate — even one
    /// that collides with another app — leaves the previous, still-working registration exactly as it
    /// was, rather than passing through a state with nothing registered at all (the failure mode this
    /// unregister-then-register-then-restore dance used to be able to manufacture on a double failure).
    /// The caller decides whether to persist `combination` based on the returned outcome.
    @discardableResult
    func apply(_ combination: HotkeyCombination) -> HotkeyRegistrationOutcome {
        let previousRef = hotKeyRef
        let outcome = register(combination)
        if case .registered = outcome, let previousRef {
            let status = UnregisterEventHotKey(previousRef)
            // Releasing a ref that was just live practically never fails, but if it does, don't
            // pretend otherwise — the old binding may still be registered at the OS level alongside
            // the new one.
            if status != noErr {
                jlog("Jarvis: hint hotkey failed to release the previous binding after rebinding "
                     + "(status \(status)).")
            }
        }
        lastOutcome = outcome
        return outcome
    }

    /// Install one application-level handler for hot-key-pressed events. The C callback can't capture
    /// context, so we hand it `self` via `userData` and recover it inside.
    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return noErr }
            let controller = Unmanaged<HotkeyController>.fromOpaque(userData).takeUnretainedValue()
            // Carbon delivers application-target hot-key events on the main thread, so it is safe to
            // assert main-actor isolation here and call back synchronously.
            MainActor.assumeIsolated { controller.onRequestHint?() }
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)
        // A failed install leaves the hot key dead; without this line that failure is invisible.
        if status != noErr { jlog("Jarvis: hint-hotkey handler install failed (status \(status)).") }
    }

    private func register(_ combination: HotkeyCombination) -> HotkeyRegistrationOutcome {
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combination.keyCode, combination.modifiers.rawValue, id,
            GetApplicationEventTarget(), 0, &ref)
        // The common failure is eventHotKeyExistsErr — another running app already owns the combo.
        // Log it so a silently-dead hotkey is diagnosable instead of looking like nothing happened
        // on press.
        guard status == noErr else {
            jlog("Jarvis: hint hotkey \(HotkeyKeyNames.displayString(for: combination)) unavailable "
                 + "(status \(status)) — another app may already own it.")
            return .failed(status: status)
        }
        hotKeyRef = ref
        registered = combination
        return .registered
    }
}
