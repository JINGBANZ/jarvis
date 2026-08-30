import AppKit
import Carbon.HIToolbox
import JarvisCore   // jlog

/// Registers a single global hotkey — ⌥⌘J — and forwards each press to `onRequestHint`. The shortcut
/// is system-wide (it fires even when Jarvis, a menu-bar accessory, isn't frontmost) via Carbon
/// `RegisterEventHotKey`, which needs no Accessibility permission and shows no permission dialog.
///
/// Carbon's hot-key API is the one global-shortcut mechanism Apple never gave a modern replacement,
/// and unlike the SwiftUI-macro-based wrapper packages it builds cleanly with the Command Line Tools
/// (no Xcode-only macro plugins). The binding is fixed for now; a rebinding UI can come later.
///
/// This type is intentionally thin: it knows nothing about sessions or the coach. `AppDelegate` owns
/// the policy (ignore-when-stopped, route through the turn box) via the callback.
@MainActor
final class HotkeyController {
    /// Called on the main actor each time the hint hotkey fires.
    var onRequestHint: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// 'JRVS' — a unique signature so our hot-key id can't be confused with another component's.
    private static let signature: OSType = 0x4A_52_56_53

    init() {
        installHandler()
        register()
    }

    // No teardown: the controller lives for the whole app run (like the menu bar and overlay), and
    // the OS reclaims the registration on process exit. The refs are retained so the hot key and its
    // handler stay alive for the app's lifetime.

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
            // assert main-actor isolation here and call back synchronously. Logged unconditionally so
            // a press that never reaches the coaching pipeline is still provably recorded here first.
            MainActor.assumeIsolated {
                jlog("Jarvis: hint hotkey ⌥⌘J pressed.")
                controller.onRequestHint?()
            }
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)
        // A failed install leaves the hot key dead; without this line that failure is invisible.
        if status != noErr { jlog("Jarvis: hint-hotkey handler install failed (status \(status)).") }
    }

    private func register() {
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        // ⌥⌘J. Carbon modifier masks (cmdKey/optionKey) differ from NSEvent's modifier flags.
        let modifiers = UInt32(cmdKey | optionKey)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_J), modifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        // The common failure is eventHotKeyExistsErr — another running app already owns ⌥⌘J. Log it so
        // a silently-dead hotkey is diagnosable instead of looking like nothing happened on press.
        if status != noErr {
            jlog("Jarvis: hint hotkey ⌥⌘J unavailable (status \(status)) — another app may already own it.")
        }
    }
}
