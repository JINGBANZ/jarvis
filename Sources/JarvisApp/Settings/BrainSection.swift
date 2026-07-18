import AppKit
import JarvisCore

/// Settings panel for the brain: the provider (OpenAI API, or a locally installed Claude Code /
/// Codex CLI running on the user's subscription), the model + reasoning effort for whichever is
/// active, and the OpenAI API key — one tab, because the four choices are one decision. The model
/// list is per provider (each remembers its own); the effort is one global setting applied to all
/// three, mapped onto each CLI's scale by `CLIBrainClient`. Installed CLIs are auto-detected
/// whenever the tab is shown; Claude's bounded status command distinguishes signed in, signed out,
/// and an unavailable probe. Selections persist immediately through `BrainPreferences`; changes
/// take effect on the next Start, since the brain client is built once per coaching run. The
/// transcription model is deliberately NOT here; it's a separate concern — which is also why the
/// key stays required: transcription always runs on it.
@MainActor
final class BrainSection: NSObject, SettingsSection {
    let title = "Brain"

    private let preferences: BrainPreferences
    private let detector: AgentCLIDetector
    private let apiKey: APIKeyControls

    private var radios: [BrainProvider: NSButton] = [:]
    private var providerNote: NSTextField?
    private var modelPopup: NSPopUpButton?
    /// The models backing the current popup rows, so selection maps back without re-deriving.
    private var listedModels: [BrainModel] = []

    init(preferences: BrainPreferences, detector: AgentCLIDetector,
         keyStore: FileSecretStore, onKeySaved: @escaping (String) -> Void) {
        self.preferences = preferences
        self.detector = detector
        self.apiKey = APIKeyControls(store: keyStore, onKeySaved: onKeySaved)
    }

    func makeView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 432))

        let providerLabel = NSTextField(labelWithString: "Provider")
        providerLabel.frame = NSRect(x: 24, y: 400, width: 200, height: 20)
        view.addSubview(providerLabel)

        for (row, provider) in BrainProvider.allCases.enumerated() {
            let radio = NSButton(radioButtonWithTitle: provider.displayName,
                                 target: self, action: #selector(providerChanged))
            radio.frame = NSRect(x: 24, y: 372 - CGFloat(row) * 28, width: 512, height: 20)
            radio.setAccessibilityLabel("Brain provider: \(provider.displayName)")
            view.addSubview(radio)
            radios[provider] = radio
        }

        let providerNote = NSTextField(labelWithString: "")
        providerNote.frame = NSRect(x: 24, y: 288, width: 512, height: 20)
        providerNote.textColor = .secondaryLabelColor
        view.addSubview(providerNote)
        self.providerNote = providerNote

        let modelLabel = NSTextField(labelWithString: "Model")
        modelLabel.frame = NSRect(x: 24, y: 256, width: 200, height: 20)
        view.addSubview(modelLabel)

        let modelPopup = NSPopUpButton(frame: NSRect(x: 24, y: 224, width: 250, height: 26))
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)
        modelPopup.setAccessibilityLabel("Brain model")
        view.addSubview(modelPopup)
        self.modelPopup = modelPopup

        // One effort for every provider, mapped onto each CLI's own scale by `CLIBrainClient`
        // (Claude Code's floor is low; Codex accepts the value unchanged).
        let effortLabel = NSTextField(labelWithString: "Reasoning Effort")
        effortLabel.frame = NSRect(x: 290, y: 256, width: 200, height: 20)
        view.addSubview(effortLabel)

        let effortPopup = NSPopUpButton(frame: NSRect(x: 290, y: 224, width: 246, height: 26))
        effortPopup.addItems(withTitles: ReasoningEffort.allCases.map(\.displayName))
        effortPopup.target = self
        effortPopup.action = #selector(effortChanged)
        effortPopup.setAccessibilityLabel("Reasoning effort")
        if let row = ReasoningEffort.allCases.firstIndex(of: preferences.effort) {
            effortPopup.selectItem(at: row)
        }
        view.addSubview(effortPopup)

        let applyNote = NSTextField(labelWithString: "Changes apply on the next Start (Stop and Start to apply now).")
        applyNote.frame = NSRect(x: 24, y: 192, width: 512, height: 20)
        applyNote.textColor = .secondaryLabelColor
        view.addSubview(applyNote)

        let keyHeader = NSTextField(labelWithString: "OpenAI API Key")
        keyHeader.frame = NSRect(x: 24, y: 158, width: 200, height: 20)
        keyHeader.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        view.addSubview(keyHeader)

        let keyNote = NSTextField(labelWithString: "Needed for voice transcription even when the brain runs on a local CLI.")
        keyNote.frame = NSRect(x: 24, y: 138, width: 512, height: 20)
        keyNote.textColor = .secondaryLabelColor
        view.addSubview(keyNote)

        apiKey.addControls(to: view, top: 112)

        refreshDetection()
        return view
    }

    /// Re-probe on every show so an install or sign-in completed while the app was open appears.
    func didBecomeActive() {
        refreshDetection()
    }

    /// Update radio titles/enablement from detection and re-aim the model/effort controls at the
    /// selected provider.
    private func refreshDetection() {
        let selected = preferences.provider
        let detected = Dictionary(uniqueKeysWithValues: detector.detectAll().map { ($0.provider, $0) })
        for (provider, radio) in radios {
            var title = provider.displayName
            var enabled = true
            if provider.usesLocalCLI {
                if let cli = detected[provider] {
                    switch cli.authenticationStatus {
                    case .signedIn: title += " — detected, signed in"
                    case .signedOut: title += " — detected, signed out"
                    case .unknown: title += " — detected, sign-in unknown"
                    }
                } else {
                    title += " — not installed"
                    enabled = false
                }
            }
            radio.title = title
            // A stored selection whose CLI has vanished stays clickable so the state is visible and
            // recoverable; Start reports the missing CLI loudly.
            radio.isEnabled = enabled || provider == selected
            radio.state = provider == selected ? .on : .off
        }
        var note = Self.note(for: selected)
        if selected.usesLocalCLI, let cli = detected[selected] {
            switch cli.authenticationStatus {
            case .signedIn:
                break
            case .signedOut:
                note += " Sign in through the CLI before starting Jarvis."
            case .unknown:
                note += " Couldn't check its sign-in status — run the CLI once if turns fail."
            }
        }
        providerNote?.stringValue = note
        reloadModels(for: selected)
    }

    private static func note(for provider: BrainProvider) -> String {
        switch provider {
        case .openAI: return "Coaching runs on the OpenAI API, billed to the key below."
        case .claudeCode: return "Coaching runs through your local Claude Code CLI — billed to your Claude subscription."
        case .codexCLI: return "Coaching runs through your local Codex CLI — billed to your ChatGPT subscription."
        }
    }

    private func reloadModels(for provider: BrainProvider) {
        guard let popup = modelPopup else { return }
        listedModels = BrainModelCatalog.models(for: provider)
        popup.removeAllItems()
        popup.addItems(withTitles: listedModels.map(\.displayName))
        if let row = listedModels.firstIndex(of: preferences.model(for: provider)) {
            popup.selectItem(at: row)
        }
    }

    @objc private func providerChanged(_ sender: NSButton) {
        guard let provider = radios.first(where: { $0.value === sender })?.key else { return }
        preferences.provider = provider
        refreshDetection()
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        let row = sender.indexOfSelectedItem
        guard listedModels.indices.contains(row) else { return }
        preferences.setModel(listedModels[row], for: preferences.provider)
    }

    @objc private func effortChanged(_ sender: NSPopUpButton) {
        let row = sender.indexOfSelectedItem
        guard ReasoningEffort.allCases.indices.contains(row) else { return }
        preferences.effort = ReasoningEffort.allCases[row]
    }
}
