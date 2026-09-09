import AppKit
import JarvisCore

/// Independent bindings share the same recorder and honest registration-failure behavior.
@MainActor
final class HotkeySection: NSObject, SettingsSection {
    let title = "Shortcuts"
    let fillsTab = true
    private let bindings: [HotkeyBindingView]

    init(preferences: [HotkeyPreferences],
         explanationPreferences: ExplanationPreferences,
         boxEnabled: @escaping () -> Bool = { true },
         onExplanationsChanged: @escaping () -> Void,
         hasActiveHotkey: @escaping (CoachingShortcut) -> Bool,
         applyCombination: @escaping (CoachingShortcut, HotkeyCombination) -> HotkeyRegistrationOutcome) {
        bindings = preferences.map { preference in
            HotkeyBindingView(preferences: preference,
                explanationPreferences: preference.shortcut == .explainMore ? explanationPreferences : nil,
                boxEnabled: boxEnabled,
                onExplanationsChanged: onExplanationsChanged,
                hasActiveHotkey: { hasActiveHotkey(preference.shortcut) },
                applyCombination: { applyCombination(preference.shortcut, $0) })
        }
    }

    func makeView() -> NSView {
        let scroll = SettingsScrollView(frame: NSRect(x: 0, y: 0, width: 712, height: 432))
        scroll.autoresizingMask = [.width, .height]
        let stack = NSStackView(frame: scroll.bounds)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.distribution = .fill
        stack.spacing = SettingsStyle.sectionSpacing
        stack.autoresizingMask = [.width]
        for binding in bindings { stack.addArrangedSubview(binding.makeView()) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(0, after: last) }
        stack.addArrangedSubview(spacer)
        scroll.documentView = stack
        var previousViewportHeight = scroll.contentView.bounds.height
        let relayout: () -> Void = { [weak self, weak scroll, weak stack] in
            guard let self, let scroll, let stack else { return }
            // The stack is non-flipped: retain the reading offset from its top as cards resize.
            let distanceFromTop = max(0, stack.bounds.height
                - scroll.contentView.bounds.origin.y - previousViewportHeight)
            previousViewportHeight = scroll.contentView.bounds.height
            let height = self.bindings.reduce(CGFloat(0)) { $0 + $1.preferredHeight }
                + CGFloat(max(0, self.bindings.count - 1)) * SettingsStyle.sectionSpacing
            stack.frame.size = NSSize(width: scroll.contentView.bounds.width,
                                      height: max(height, scroll.contentView.bounds.height))
            stack.layoutSubtreeIfNeeded()
            let maximumY = max(0, stack.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0,
                y: min(maximumY, max(0, maximumY - distanceFromTop))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        bindings.forEach { $0.onHeightChanged = relayout }
        scroll.onViewportChanged = relayout
        relayout()
        return SettingsPageView(title: title,
            summary: "Request a next step or an explanation when you need more help.", bodyView: scroll)
    }

    func didBecomeActive() {
        bindings.forEach { $0.didBecomeActive() }
    }
}
