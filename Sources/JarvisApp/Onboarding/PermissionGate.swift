import AppKit
import JarvisCore

// Design: wiki/architecture.md#permissions
@MainActor
final class PermissionGate: NSObject, NSWindowDelegate {
    static let required = Set(JarvisReadiness.Permission.allCases)

    /// The host builds the rest of the app only after this fires.
    var onSatisfied: (() -> Void)?

    private let preferences: PermissionPreferences
    private var window: NSWindow?
    private var checklist: PermissionsChecklistView?
    private var isSatisfied = false

    private static let contentSize = NSSize(width: 560, height: 404)

    init(preferences: PermissionPreferences) {
        self.preferences = preferences
    }

    /// Runs the system-audio probe, which may prompt, only once the readable grants are held.
    func holdsEveryGrant() async -> Bool {
        // Clear the asked marker once granted, or a later TCC reset would read as a refusal.
        if Permissions.isGranted(.screenRecording) {
            preferences.screenRecordingAsked = false
        }
        let readable = Self.required.subtracting([.systemAudio])
        guard Permissions.grantedReadinessPermissions().isSuperset(of: readable) else { return false }
        return await Permissions.request(.systemAudio, remembering: preferences)
    }

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
            // Closing unsatisfied is declining, and Jarvis cannot coach without the grants.
            NSApp.terminate(nil)
            return
        }
        checklist?.stopObservingActivation()
        onSatisfied?()
    }
}
