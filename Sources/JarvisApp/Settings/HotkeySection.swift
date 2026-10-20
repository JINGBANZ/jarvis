import AppKit
import JarvisCore

@MainActor
final class HotkeySection: NSObject {
    private let bindings: [HotkeyBindingView]
    private let mouseBindings: [MouseHotkeyBindingView]
    private var stack: SettingsCardStack?

    init(preferences: [HotkeyPreferences],
         mouseController: MouseHotkeyController,
         hasActiveHotkey: @escaping (CoachingShortcut) -> Bool,
         applyCombination: @escaping (CoachingShortcut, HotkeyCombination) -> HotkeyRegistrationOutcome) {
        mouseBindings = preferences.map {
            MouseHotkeyBindingView(preferences: $0, controller: mouseController)
        }
        bindings = preferences.map { preference in
            HotkeyBindingView(preferences: preference,
                hasActiveHotkey: { hasActiveHotkey(preference.shortcut) },
                applyCombination: { applyCombination(preference.shortcut, $0) })
        }
    }

    func makeView() -> NSView {
        let rows = bindings.enumerated().map { index, binding in
            binding.makeRow(mouseBinding: mouseBindings[index], showsSeparator: index > 0)
        }
        var height = CGFloat(rows.count) * ShortcutSettingsRowView.height(for: 600)
        let card = SettingsCardView(frame: NSRect(x: 0, y: 0, width: 712, height: height))
        let headings = ["Action", "Keyboard", "Mouse"].map { text in
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 10.5)
            label.textColor = SettingsTheme.mutedText
            card.contentView?.addSubview(label)
            return label
        }
        rows.forEach { card.contentView?.addSubview($0) }
        let stack = SettingsCardStack()
        card.onLayout = { [weak card, weak stack] in
            guard let card else { return }
            let body = card.bodyFrame
            let narrow = body.width < 530
            let headerHeight: CGFloat = narrow ? 0 : 30
            let rowHeight = ShortcutSettingsRowView.height(for: body.width)
            let newHeight = CGFloat(rows.count) * rowHeight + headerHeight
            if height != newHeight {
                height = newHeight
                stack?.setHeight(height, for: card)
            }
            headings.forEach { $0.isHidden = narrow }
            headings[0].frame = NSRect(x: 16, y: body.maxY - 25, width: 150, height: 18)
            headings[1].alignment = .center
            headings[1].frame = NSRect(x: body.width - 270, y: body.maxY - 25, width: 106, height: 18)
            headings[2].alignment = .center
            headings[2].frame = NSRect(x: body.width - 152, y: body.maxY - 25, width: 136, height: 18)
            for (index, row) in rows.enumerated() {
                row.frame = NSRect(
                    x: body.minX, y: body.maxY - headerHeight - CGFloat(index + 1) * rowHeight,
                    width: body.width, height: rowHeight)
            }
        }
        height += 30
        stack.install([(card, height)])
        self.stack = stack
        return stack.scrollView
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
