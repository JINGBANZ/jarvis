import AppKit
import JarvisCore

/// Settings panel for the brain: the provider (OpenAI API, or a locally installed Claude Code /
/// Codex CLI running on the user's subscription), the model + reasoning effort for whichever is
/// active, an optional fallback provider, and the OpenAI API key — one tab, because these choices are
/// one decision. The model list is per provider (each remembers its own); the effort is one global
/// setting applied to all three, mapped onto each CLI's scale by `CLIBrainClient`. Installed CLIs are
/// auto-detected
/// whenever the tab is shown; Claude's bounded status command distinguishes signed in, signed out,
/// and an unavailable probe. Selections persist immediately through `BrainPreferences`; while
/// coaching, the driver swaps its model clients for the next turn without resetting transcript or
/// history. The transcription model is deliberately NOT here; it's a separate concern — which is
/// also why the key stays required: transcription always runs on it.
@MainActor
final class BrainSection: NSObject, SettingsSection {
    let title = "Brain"

    private let preferences: BrainPreferences
    private let detector: AgentCLIDetector
    private let onPreferencesChanged: ([BrainProvider: DetectedAgentCLI]?) -> Void
    private let apiKey: APIKeyControls

    private var radios: [BrainProvider: NSButton] = [:]
    private var providerNote: NSTextField?
    private var fallbackPopup: NSPopUpButton?
    private var fallbackNote: NSTextField?
    private var listedFallbackProviders: [BrainProvider?] = []
    private var modelPopup: NSPopUpButton?
    /// The models backing the current popup rows, so selection maps back without re-deriving.
    private var listedModels: [BrainModel] = []
    /// The latest completed probe remains usable while the next refresh runs in the background.
    private var detectedCLIs: [BrainProvider: DetectedAgentCLI]?
    /// Deliberately survives a Settings close so a local-provider edit made during the probe still
    /// reaches the running coaching session when detection finishes.
    private var detectionTask: Task<Void, Never>?
    /// Several edits during one probe collapse into one application of the latest persisted values.
    private var applyPreferencesAfterDetection = false

    init(preferences: BrainPreferences, detector: AgentCLIDetector,
         onPreferencesChanged: @escaping ([BrainProvider: DetectedAgentCLI]?) -> Void,
         keyStore: FileSecretStore, onKeySaved: @escaping (String) -> Void) {
        self.preferences = preferences
        self.detector = detector
        self.onPreferencesChanged = onPreferencesChanged
        self.apiKey = APIKeyControls(store: keyStore, onKeySaved: onKeySaved)
    }

    func makeView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 432))

        let providerLabel = NSTextField(labelWithString: "Provider")
        providerLabel.frame = NSRect(x: 24, y: 400, width: 252, height: 20)
        view.addSubview(providerLabel)

        for (row, provider) in BrainProvider.allCases.enumerated() {
            let radio = NSButton(radioButtonWithTitle: provider.displayName,
                                 target: self, action: #selector(providerChanged))
            radio.frame = NSRect(x: 24, y: 372 - CGFloat(row) * 28, width: 252, height: 20)
            radio.setAccessibilityLabel("Brain provider: \(provider.displayName)")
            view.addSubview(radio)
            radios[provider] = radio
        }

        let fallbackLabel = NSTextField(labelWithString: "Fallback Provider")
        fallbackLabel.frame = NSRect(x: 300, y: 400, width: 236, height: 20)
        view.addSubview(fallbackLabel)

        let fallbackPopup = NSPopUpButton(
            frame: NSRect(x: 300, y: 368, width: 236, height: 26))
        fallbackPopup.target = self
        fallbackPopup.action = #selector(fallbackChanged)
        fallbackPopup.setAccessibilityLabel("Fallback brain provider")
        view.addSubview(fallbackPopup)
        self.fallbackPopup = fallbackPopup

        let fallbackNote = NSTextField(wrappingLabelWithString: "")
        fallbackNote.frame = NSRect(x: 300, y: 310, width: 236, height: 50)
        fallbackNote.textColor = .secondaryLabelColor
        view.addSubview(fallbackNote)
        self.fallbackNote = fallbackNote

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

        let applyNote = NSTextField(
            labelWithString: "Changes apply on the next coaching turn (or the next Start while stopped).")
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

        renderDetection()
        return view
    }

    /// Re-probe whenever the tab becomes visible so an install or sign-in completed while the app
    /// was open appears. The subprocesses stay off the main actor; cached or base labels render
    /// immediately and the status suffixes update when detection finishes.
    func didBecomeActive() {
        refreshDetection()
    }

    private func refreshDetection() {
        guard detectionTask == nil else { return }
        let detector = detector
        detectionTask = Task { [weak self] in
            let values = await detector.detectAllAsync()
            guard !Task.isCancelled, let self else { return }
            detectionTask = nil
            detectedCLIs = Dictionary(uniqueKeysWithValues: values.map { ($0.provider, $0) })
            renderDetection()
            if applyPreferencesAfterDetection {
                applyPreferencesAfterDetection = false
                onPreferencesChanged(detectedCLIs)
            }
        }
    }

    /// Update radio titles/enablement from the most recent detection and re-aim the model controls at
    /// the selected provider. Before the first probe completes, local providers stay selectable and
    /// use their base labels rather than being misreported as missing.
    private func renderDetection() {
        let selected = preferences.provider
        for (provider, radio) in radios {
            var title = provider.displayName
            var enabled = true
            if provider.usesLocalCLI, let detectedCLIs {
                if let cli = detectedCLIs[provider] {
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
        if selected.usesLocalCLI, let cli = detectedCLIs?[selected] {
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
        reloadFallbackProviders(primary: selected)
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

    private func reloadFallbackProviders(primary: BrainProvider) {
        guard let popup = fallbackPopup else { return }
        listedFallbackProviders = [nil] + BrainProvider.allCases
            .filter { $0 != primary }
            .map(Optional.some)
        popup.removeAllItems()
        popup.addItems(withTitles: listedFallbackProviders.map {
            $0?.displayName ?? "Disabled"
        })
        let selected = preferences.fallbackProvider
        if let row = listedFallbackProviders.firstIndex(where: { $0 == selected }) {
            popup.selectItem(at: row)
        }
        for (row, provider) in listedFallbackProviders.enumerated() {
            guard let provider, provider.usesLocalCLI, let detectedCLIs else { continue }
            popup.item(at: row)?.isEnabled =
                detectedCLIs[provider] != nil || provider == selected
        }
        guard let selected else {
            fallbackNote?.stringValue =
                "Disabled. Jarvis keeps listening after a temporary provider miss."
            return
        }
        var note = "Continues the same conversation after \(primary.displayName) exhausts retries."
        if selected.usesLocalCLI, let detectedCLIs {
            if let cli = detectedCLIs[selected] {
                switch cli.authenticationStatus {
                case .signedIn:
                    break
                case .signedOut:
                    note += " Sign in before it can be applied."
                case .unknown:
                    note += " Sign-in couldn't be confirmed."
                }
            } else {
                note += " The CLI isn't installed."
            }
        }
        fallbackNote?.stringValue = note
    }

    @objc private func providerChanged(_ sender: NSButton) {
        guard let provider = radios.first(where: { $0.value === sender })?.key else { return }
        preferences.provider = provider
        renderDetection()
        preferencesDidChange()
    }

    @objc private func fallbackChanged(_ sender: NSPopUpButton) {
        let row = sender.indexOfSelectedItem
        guard listedFallbackProviders.indices.contains(row) else { return }
        preferences.fallbackProvider = listedFallbackProviders[row]
        renderDetection()
        preferencesDidChange()
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        let row = sender.indexOfSelectedItem
        guard listedModels.indices.contains(row) else { return }
        preferences.setModel(listedModels[row], for: preferences.provider)
        preferencesDidChange()
    }

    @objc private func effortChanged(_ sender: NSPopUpButton) {
        let row = sender.indexOfSelectedItem
        guard ReasoningEffort.allCases.indices.contains(row) else { return }
        preferences.effort = ReasoningEffort.allCases[row]
        preferencesDidChange()
    }

    private func preferencesDidChange() {
        let providers = [preferences.provider, preferences.fallbackProvider]
            .compactMap { $0 }
        guard providers.contains(where: \.usesLocalCLI) else {
            applyPreferencesAfterDetection = false
            onPreferencesChanged([:])
            return
        }
        // Never apply a cached preflight while a fresher probe is running. The completion collapses
        // any edits made during that probe into one application of the latest persisted preferences.
        if detectionTask != nil {
            applyPreferencesAfterDetection = true
            return
        }
        if let detectedCLIs {
            onPreferencesChanged(detectedCLIs)
        } else {
            applyPreferencesAfterDetection = true
            refreshDetection()
        }
    }
}
