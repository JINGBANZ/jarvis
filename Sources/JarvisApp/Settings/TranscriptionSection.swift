import AppKit
import JarvisCore

@MainActor
final class TranscriptionSection: NSObject, SettingsSection {
    let destination = SettingsDestination.ear

    private let controls: TranscriptionControls
    private var stack: SettingsCardStack?
    private var card: NSView?

    init(preferences: TranscriptionPreferences) {
        controls = TranscriptionControls(preferences: preferences)
    }

    func makePage() -> SettingsPageView {
        let stack = SettingsCardStack()
        let card = controls.makeView { [weak self] height in
            guard let self, let card = self.card else { return }
            self.stack?.setHeight(height, for: card)
        }
        self.card = card
        self.stack = stack
        stack.install([(card, controls.preferredHeight)])
        return SettingsPageView(
            title: "Ear",
            summary: "How I turn the conversation into text.",
            chip: .neutral("Applies next start"),
            part: .ear,
            bodyView: stack.scrollView)
    }

    func windowWillClose() {
        card = nil
        stack = nil
    }
}
