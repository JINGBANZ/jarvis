import AppKit
import JarvisCore

@MainActor
final class HotkeySection: NSObject, SettingsSection {
    let destination = SettingsDestination.shortcuts
    private let bindings: [HotkeyBindingView]
    private let mouseBindings: [MouseHotkeyBindingView]
    private var stack: SettingsCardStack?

    init(preferences: [HotkeyPreferences],
         mouseController: MouseHotkeyController,
         boxEnabled: @escaping () -> Bool = { true },
         hasActiveHotkey: @escaping (CoachingShortcut) -> Bool,
         applyCombination: @escaping (CoachingShortcut, HotkeyCombination) -> HotkeyRegistrationOutcome) {
        mouseBindings = preferences.map {
            MouseHotkeyBindingView(preferences: $0, controller: mouseController, boxEnabled: boxEnabled)
        }
        bindings = preferences.map { preference in
            HotkeyBindingView(preferences: preference,
                boxEnabled: boxEnabled,
                hasActiveHotkey: { hasActiveHotkey(preference.shortcut) },
                applyCombination: { applyCombination(preference.shortcut, $0) })
        }
    }

    func makePage() -> SettingsPageView {
        let rows = bindings.enumerated().flatMap { index, binding in
            [binding.makeRow(showsSeparator: index > 0), mouseBindings[index].makeRow()]
        }
        let height = CGFloat(rows.count) * SettingsStyle.rowHeight
        let card = SettingsCardView(frame: NSRect(x: 0, y: 0, width: 712, height: height))
        rows.forEach { card.contentView?.addSubview($0) }
        card.onLayout = { [weak card] in
            guard let card else { return }
            let body = card.bodyFrame
            for (index, row) in rows.enumerated() {
                row.frame = NSRect(
                    x: body.minX, y: body.maxY - CGFloat(index + 1) * SettingsStyle.rowHeight,
                    width: body.width, height: SettingsStyle.rowHeight)
            }
        }
        let stack = SettingsCardStack()
        stack.install([(card, height)])
        self.stack = stack
        return SettingsPageView(
            title: "Shortcuts",
            summary: "Ask me for help, or step through my details.",
            chip: .neutral("Works during a session"),
            bodyView: stack.scrollView)
    }

    func didBecomeActive() {
        bindings.forEach { $0.didBecomeActive() }
        mouseBindings.forEach { $0.refresh() }
    }

    func didResignActive() {
        bindings.forEach { $0.didBecomeActive() }
        mouseBindings.forEach { $0.stopRecording() }
    }

    func windowWillClose() {
        didResignActive()
        stack = nil
    }
}
