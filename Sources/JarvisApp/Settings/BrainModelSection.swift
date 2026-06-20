import AppKit
import JarvisCore

/// Settings panel for the brain (LLM) model and its reasoning effort. Two independent dropdowns —
/// the model and the effort applied to it — persisted immediately through `BrainPreferences`. The
/// transcription model is deliberately NOT here; it's a separate concern. Changes take effect on the
/// next Start, since the brain client is built once per coaching run.
@MainActor
final class BrainModelSection: NSObject, SettingsSection {
    let title = "Brain"

    private let preferences: BrainPreferences

    init(preferences: BrainPreferences) {
        self.preferences = preferences
    }

    func makeView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 432))

        let modelLabel = NSTextField(labelWithString: "Model")
        modelLabel.frame = NSRect(x: 24, y: 372, width: 200, height: 20)
        view.addSubview(modelLabel)

        let modelPopup = NSPopUpButton(frame: NSRect(x: 24, y: 340, width: 320, height: 26))
        modelPopup.addItems(withTitles: BrainModelCatalog.all.map(\.displayName))
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)
        modelPopup.setAccessibilityLabel("Brain model")
        if let row = BrainModelCatalog.all.firstIndex(of: preferences.model) {
            modelPopup.selectItem(at: row)
        }
        view.addSubview(modelPopup)

        let effortLabel = NSTextField(labelWithString: "Reasoning Effort")
        effortLabel.frame = NSRect(x: 24, y: 292, width: 200, height: 20)
        view.addSubview(effortLabel)

        let effortPopup = NSPopUpButton(frame: NSRect(x: 24, y: 260, width: 320, height: 26))
        effortPopup.addItems(withTitles: ReasoningEffort.allCases.map(\.displayName))
        effortPopup.target = self
        effortPopup.action = #selector(effortChanged)
        effortPopup.setAccessibilityLabel("Reasoning effort")
        if let row = ReasoningEffort.allCases.firstIndex(of: preferences.effort) {
            effortPopup.selectItem(at: row)
        }
        view.addSubview(effortPopup)

        let note = NSTextField(labelWithString: "Changes apply on the next Start (Stop and Start to apply now).")
        note.frame = NSRect(x: 24, y: 222, width: 512, height: 20)
        note.textColor = .secondaryLabelColor
        view.addSubview(note)

        return view
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        let row = sender.indexOfSelectedItem
        guard BrainModelCatalog.all.indices.contains(row) else { return }
        preferences.model = BrainModelCatalog.all[row]
    }

    @objc private func effortChanged(_ sender: NSPopUpButton) {
        let row = sender.indexOfSelectedItem
        guard ReasoningEffort.allCases.indices.contains(row) else { return }
        preferences.effort = ReasoningEffort.allCases[row]
    }
}
