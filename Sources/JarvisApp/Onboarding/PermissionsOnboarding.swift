import AppKit
import JarvisCore

/// First-launch permission gathering. Shows the checklist once, so every macOS prompt lands while
/// the user is setting Jarvis up rather than in the middle of a conversation.
///
/// It guides rather than gates: the window closes whenever the user wants, Start reports whatever
/// they skipped as a typed blocker, and the Permissions tab in Settings hosts the same checklist for
/// later. Presenting here is safe by construction — no session can be live at launch.
@MainActor
final class PermissionsOnboarding: NSObject, NSWindowDelegate {
    private let preferences: PermissionPreferences
    private var window: NSWindow?
    private var checklist: PermissionsChecklistView?
    private var dismissButton: ClosureButton?

    private static let contentSize = NSSize(width: 688, height: 486)

    init(preferences: PermissionPreferences) {
        self.preferences = preferences
    }

    /// Presents the checklist on a first run. On later launches it re-probes a system-audio grant
    /// Jarvis has never seen succeed — silent for a user who refused, since macOS answers for them
    /// — so an undecided grant is settled at launch instead of at Start.
    func runAtLaunch() {
        guard !preferences.onboardingShown else {
            guard !preferences.systemAudioGranted else { return }
            Task { @MainActor in
                _ = await Permissions.request(.systemAudio, remembering: preferences)
            }
            return
        }
        // Recorded before presenting: a checklist the user closes without granting anything must
        // not come back at every launch.
        preferences.onboardingShown = true
        show()
    }

    func show() {
        NSApp.setActivationPolicy(.regular) // ghost-mode-allowed: first-launch permission setup
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true) // ghost-mode-allowed: first-launch permission setup
        window?.makeKeyAndOrderFront(nil) // ghost-mode-allowed: first-launch permission setup
    }

    private func build() {
        let window = EscapableWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Welcome to Jarvis"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let content = NSView(frame: NSRect(origin: .zero, size: Self.contentSize))
        let inset = SettingsStyle.pageHorizontalInset
        let width = Self.contentSize.width - inset * 2

        let title = NSTextField(labelWithString: "Jarvis needs three permissions")
        title.font = .boldSystemFont(ofSize: 21)
        let summary = NSTextField(
            labelWithString: "Grant them now and macOS won't interrupt a live session to ask.")
        summary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summary.textColor = .secondaryLabelColor

        let checklist = PermissionsChecklistView(preferences: preferences)
        let dismissButton = ClosureButton(title: "Not now") { [weak self] in
            self?.window?.performClose(nil)
        }
        dismissButton.bezelStyle = .rounded
        checklist.onStateChange = { [weak checklist, weak dismissButton] in
            guard let checklist, let dismissButton else { return }
            dismissButton.title = checklist.isComplete ? "Done" : "Not now"
        }

        var top = Self.contentSize.height - SettingsStyle.pageTopInset - 26
        title.frame = NSRect(x: inset, y: top, width: width, height: 26)
        top -= 22
        summary.frame = NSRect(x: inset, y: top, width: width, height: 18)
        top -= PermissionsChecklistView.preferredHeight + SettingsStyle.pageHeaderSpacing
        checklist.frame = NSRect(x: inset, y: top,
                                 width: width, height: PermissionsChecklistView.preferredHeight)
        dismissButton.frame = NSRect(x: Self.contentSize.width - inset - 110,
                                     y: SettingsStyle.pageBottomInset, width: 110, height: 32)

        for view in [title, summary, checklist, dismissButton] { content.addSubview(view) }
        window.contentView = content
        self.window = window
        self.checklist = checklist
        self.dismissButton = dismissButton
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu-bar-only app; the window is kept so Settings can't be shadowed by a
        // half-torn-down one.
        NSApp.setActivationPolicy(.accessory) // ghost-mode-allowed: restoring the menu-bar-only app
    }
}
