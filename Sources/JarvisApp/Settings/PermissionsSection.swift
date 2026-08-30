import AppKit
import JarvisCore

/// Settings panel for the macOS grants Jarvis needs.
///
/// The same checklist the first-launch window shows. It exists because macOS never re-prompts once
/// a user has refused — without a way back, a skipped permission could only be fixed by hunting
/// through System Settings.
@MainActor
final class PermissionsSection: NSObject, SettingsSection {
    let title = "Permissions"
    let fillsTab = true

    private let preferences: PermissionPreferences
    private var checklist: PermissionsChecklistView?

    init(preferences: PermissionPreferences) {
        self.preferences = preferences
    }

    func makeView() -> NSView {
        let checklist = PermissionsChecklistView(preferences: preferences)
        checklist.translatesAutoresizingMaskIntoConstraints = false
        self.checklist = checklist

        let body = NSView(frame: NSRect(x: 0, y: 0, width: 712, height: 432))
        body.addSubview(checklist)
        NSLayoutConstraint.activate([
            checklist.topAnchor.constraint(equalTo: body.topAnchor),
            checklist.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            checklist.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            checklist.heightAnchor.constraint(
                equalToConstant: PermissionsChecklistView.preferredHeight),
        ])

        return SettingsPageView(
            title: "Permissions",
            summary: "What macOS lets Jarvis hear and see. Granted once, in System Settings.",
            bodyView: body)
    }

    /// A grant can change in System Settings while Jarvis is running, so re-read on every visit.
    func didBecomeActive() {
        checklist?.refresh()
    }
}
