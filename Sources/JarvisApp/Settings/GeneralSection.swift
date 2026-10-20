import AppKit
import JarvisCore

@MainActor
final class GeneralSection: NSObject, SettingsSection {
    let destination = SettingsDestination.general
    private let preferences: BrainPreferences
    private let shortcuts: HotkeySection
    private var storageSwitch: NSSwitch?

    init(preferences: BrainPreferences, shortcuts: HotkeySection) {
        self.preferences = preferences
        self.shortcuts = shortcuts
    }

    func makePage() -> SettingsPageView {
        let body = GeneralSettingsView(shortcuts: shortcuts.makeView(), privacy: makePrivacyView())
        body.onSelectionChanged = { [weak shortcuts] in shortcuts?.didResignActive() }
        return SettingsPageView(title: "General", summary: "", bodyView: body)
    }

    func didBecomeActive() {
        shortcuts.didBecomeActive()
        storageSwitch?.state = preferences.saveConversations ? .on : .off
    }

    func didResignActive() { shortcuts.didResignActive() }

    func windowWillClose() {
        shortcuts.windowWillClose()
        storageSwitch = nil
    }

    private func makePrivacyView() -> NSView {
        let body = NSView()
        let card = SettingsCardView(frame: .zero)
        let title = NSTextField(wrappingLabelWithString: "Save conversations with AI providers")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = SettingsTheme.text
        let detail = NSTextField(wrappingLabelWithString:
            "Allow providers to keep a saved copy of your requests and replies.")
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = SettingsTheme.mutedText
        let toggle = NSSwitch()
        toggle.state = preferences.saveConversations ? .on : .off
        toggle.target = self
        toggle.action = #selector(storageChanged)
        toggle.setAccessibilityLabel(title.stringValue)
        storageSwitch = toggle
        let note = NSTextField(wrappingLabelWithString:
            "Applies next session. Local Jarvis history is unchanged.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = SettingsTheme.mutedText
        [card, note].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; body.addSubview($0) }
        guard let content = card.contentView else { return body }
        [title, detail, toggle].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: body.topAnchor),
            card.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -18),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 7),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            toggle.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            toggle.topAnchor.constraint(equalTo: title.topAnchor),
            toggle.widthAnchor.constraint(equalToConstant: 38),
            note.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 12),
            note.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: body.trailingAnchor),
        ])
        return body
    }

    @objc private func storageChanged(_ sender: NSSwitch) {
        preferences.saveConversations = sender.state == .on
    }
}
