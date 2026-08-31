import AppKit
import JarvisCore

/// The launch gate. Jarvis needs Microphone, System Audio Recording, and Screen Recording to coach
/// at all, so it asks for them at launch and stays closed until it holds all three.
///
/// Two reasons it is a gate rather than a prompt. A TCC dialog is system UI that no
/// capture-exclusion trick hides, so one arriving at the first Start lands in the middle of an
/// interview, over a shared screen. And a half-granted install is not a usable product — it would
/// only fail later, further from the cause.
///
/// The window's close button quits Jarvis: grant or quit is the whole choice. Nothing records that
/// the gate has run, because it is shown exactly when the grants are incomplete — a refusal simply
/// brings it back next launch, which is also the only way back in, since macOS never re-prompts.
@MainActor
final class PermissionGate: NSObject, NSWindowDelegate {
    /// Every grant Jarvis requires before it will run.
    static let required = Set(JarvisReadiness.Permission.allCases)

    /// Called once Jarvis holds every grant and the user has asked to get on with it. The host
    /// builds the rest of the app then, and not before.
    var onSatisfied: (() -> Void)?

    private let preferences: PermissionPreferences
    private var window: NSWindow?
    private var checklist: PermissionsChecklistView?
    /// Set once the user has finished, so closing the window stops meaning "quit".
    private var isSatisfied = false

    private static let contentSize = NSSize(width: 560, height: 404)

    init(preferences: PermissionPreferences) {
        self.preferences = preferences
    }

    /// Whether macOS holds every required grant, re-proving the remembered system-audio answer
    /// first.
    ///
    /// A remembered `true` cannot simply be trusted: the user may have switched the grant off in
    /// System Settings since, and nothing downstream would notice. A refused tap still delivers
    /// frames, and `CaptureReadinessMonitor` reads frame arrival as healthy without inspecting
    /// amplitude, so Jarvis would report full readiness while deaf to the other side of the
    /// conversation. Only a remembered grant is re-proved; a remembered refusal is left alone,
    /// because probing it here would raise a prompt with no window on screen to explain it.
    func holdsEveryGrant() async -> Bool {
        if preferences.systemAudioGranted {
            _ = await Permissions.request(.systemAudio, remembering: preferences)
        }
        return Permissions.grantedReadinessPermissions(remembering: preferences)
            .isSuperset(of: Self.required)
    }

    /// Puts the gate on screen. The caller checks `isOpen` first; there is no menu bar, overlay, or
    /// session runtime behind this window until it closes satisfied.
    func present() {
        NSApp.setActivationPolicy(.regular) // ghost-mode-allowed: launch permission gate
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true) // ghost-mode-allowed: launch permission gate
        window?.makeKeyAndOrderFront(nil) // ghost-mode-allowed: launch permission gate
    }

    private func build() {
        let window = EscapableWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Welcome to Jarvis"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let checklist = PermissionsChecklistView(preferences: preferences)
        checklist.onFinished = { [weak self] in
            self?.isSatisfied = true
            self?.window?.performClose(nil)
        }
        checklist.onQuit = { NSApp.terminate(nil) }

        let content = NSView(frame: NSRect(origin: .zero, size: Self.contentSize))
        content.addSubview(checklist)
        checklist.frame = content.bounds
        checklist.autoresizingMask = [.width, .height]

        window.contentView = content
        self.window = window
        self.checklist = checklist
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // ghost-mode-allowed: restoring the menu-bar-only app
        guard isSatisfied else {
            // Closing an unsatisfied gate is the user declining to grant. Jarvis cannot coach
            // without these, so it leaves rather than lurking in the menu bar unable to start.
            NSApp.terminate(nil)
            return
        }
        onSatisfied?()
    }
}
