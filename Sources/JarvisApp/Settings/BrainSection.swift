import AppKit
import JarvisCore

/// Settings panel for the brain: the provider (OpenAI API, or a locally installed Claude Code /
/// Codex CLI running on the user's subscription), the model + reasoning effort for whichever is
/// active, an ordered fallback route, and the OpenAI API key — one tab, because these choices are one
/// decision. Every fallback row is a provider/model target; rows may reuse one provider with
/// different models, but exact targets stay unique. The model list is per provider (each remembers
/// its own); the effort is one global setting applied to all three, mapped onto each CLI's scale by
/// `CLIBrainClient`. Installed CLIs are auto-detected whenever the tab is shown; Claude's bounded
/// status command distinguishes signed in, signed out, and an unavailable probe. Every list edit
/// persists immediately through `BrainPreferences`; while coaching, the driver applies the new route
/// between attempts without resetting transcript or history. The transcription model is deliberately
/// NOT here; it's a separate concern — which is also why the key stays required: transcription always
/// runs on it.
@MainActor
final class BrainSection: NSObject, SettingsSection {
    let title = "Brain"
    let fillsTab = true

    private let preferences: BrainPreferences
    private let detector: AgentCLIDetector
    private let onPreferencesChanged: ([BrainProvider: DetectedAgentCLI]?) -> Void
    private let apiKey: APIKeyControls

    private var radios: [BrainProvider: NSButton] = [:]
    private var providerNote: NSTextField?
    private var routeStatus: NSTextField?
    private var fallbackEditor: FallbackRouteEditor?
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
    /// Session-local runtime state only. This marker never writes preferences or reorders the route.
    private var activeTarget: BrainTarget?

    init(preferences: BrainPreferences, detector: AgentCLIDetector,
         onPreferencesChanged: @escaping ([BrainProvider: DetectedAgentCLI]?) -> Void,
         keyStore: FileSecretStore, onKeySaved: @escaping (String) -> Void) {
        self.preferences = preferences
        self.detector = detector
        self.onPreferencesChanged = onPreferencesChanged
        self.apiKey = APIKeyControls(store: keyStore, onKeySaved: onKeySaved)
    }

    func makeView() -> NSView {
        // The route editor adds useful vertical content but Settings must still fit its established
        // minimum window. Keep the form at a comfortable fixed width and scroll the whole tab when
        // needed instead of squeezing list rows or enlarging every Settings section.
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 432))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 690))
        scrollView.documentView = view

        let providerLabel = NSTextField(labelWithString: "Provider")
        providerLabel.frame = NSRect(x: 24, y: 658, width: 252, height: 20)
        view.addSubview(providerLabel)

        for (row, provider) in BrainProvider.allCases.enumerated() {
            let radio = NSButton(radioButtonWithTitle: provider.displayName,
                                 target: self, action: #selector(providerChanged))
            radio.frame = NSRect(x: 24, y: 630 - CGFloat(row) * 28, width: 512, height: 20)
            radio.setAccessibilityLabel("Brain provider: \(provider.displayName)")
            view.addSubview(radio)
            radios[provider] = radio
        }

        let providerNote = NSTextField(labelWithString: "")
        providerNote.frame = NSRect(x: 24, y: 544, width: 512, height: 20)
        providerNote.textColor = .secondaryLabelColor
        view.addSubview(providerNote)
        self.providerNote = providerNote

        let modelLabel = NSTextField(labelWithString: "Model")
        modelLabel.frame = NSRect(x: 24, y: 512, width: 200, height: 20)
        view.addSubview(modelLabel)

        let modelPopup = NSPopUpButton(frame: NSRect(x: 24, y: 480, width: 250, height: 26))
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)
        modelPopup.setAccessibilityLabel("Brain model")
        view.addSubview(modelPopup)
        self.modelPopup = modelPopup

        // One effort for every provider, mapped onto each CLI's own scale by `CLIBrainClient`
        // (Claude Code's floor is low; Codex accepts the value unchanged).
        let effortLabel = NSTextField(labelWithString: "Reasoning Effort")
        effortLabel.frame = NSRect(x: 290, y: 512, width: 200, height: 20)
        view.addSubview(effortLabel)

        let effortPopup = NSPopUpButton(frame: NSRect(x: 290, y: 480, width: 246, height: 26))
        effortPopup.addItems(withTitles: ReasoningEffort.allCases.map(\.displayName))
        effortPopup.target = self
        effortPopup.action = #selector(effortChanged)
        effortPopup.setAccessibilityLabel("Reasoning effort")
        if let row = ReasoningEffort.allCases.firstIndex(of: preferences.effort) {
            effortPopup.selectItem(at: row)
        }
        view.addSubview(effortPopup)

        let routeStatus = NSTextField(wrappingLabelWithString: "")
        routeStatus.frame = NSRect(x: 24, y: 438, width: 512, height: 34)
        routeStatus.textColor = .secondaryLabelColor
        view.addSubview(routeStatus)
        self.routeStatus = routeStatus

        let fallbackLabel = NSTextField(labelWithString: "Fallback Route")
        fallbackLabel.frame = NSRect(x: 24, y: 412, width: 200, height: 20)
        fallbackLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        view.addSubview(fallbackLabel)

        let fallbackEditor = FallbackRouteEditor(
            preferences: preferences,
            onChange: { [weak self] in self?.preferencesDidChange() })
        fallbackEditor.view.frame.origin = NSPoint(x: 24, y: 190)
        view.addSubview(fallbackEditor.view)
        self.fallbackEditor = fallbackEditor

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
        renderRouteStatus()
        // NSView coordinates grow upward; reveal the top of the form on first presentation.
        scrollView.contentView.scroll(
            to: NSPoint(x: 0, y: max(0, view.bounds.height - scrollView.contentView.bounds.height)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return scrollView
    }

    /// Reflect the driver's selected runtime target without mutating the saved route.
    func setActiveTarget(_ target: BrainTarget?) {
        activeTarget = target
        renderRouteStatus()
        fallbackEditor?.render(detectedCLIs: detectedCLIs, activeTarget: activeTarget)
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
        fallbackEditor?.render(detectedCLIs: detectedCLIs, activeTarget: activeTarget)
        renderRouteStatus()
    }

    private func renderRouteStatus() {
        guard let activeTarget else {
            routeStatus?.stringValue =
                "Changes apply on the next coaching attempt (or the next Start while stopped)."
            return
        }
        let position: String
        if activeTarget == preferences.primaryTarget {
            position = "Primary"
        } else if let index = preferences.fallbackTargets.firstIndex(of: activeTarget) {
            position = "Fallback \(index + 1)"
        } else {
            position = "Current route"
        }
        let model = activeTarget.model?.displayName ?? activeTarget.modelID
        routeStatus?.stringValue =
            "Live: \(position) · \(activeTarget.provider.displayName) · \(model). "
            + "Saved order is unchanged."
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
        renderDetection()
        preferencesDidChange()
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        let row = sender.indexOfSelectedItem
        guard listedModels.indices.contains(row) else { return }
        preferences.setModel(listedModels[row], for: preferences.provider)
        fallbackEditor?.render(detectedCLIs: detectedCLIs, activeTarget: activeTarget)
        preferencesDidChange()
    }

    @objc private func effortChanged(_ sender: NSPopUpButton) {
        let row = sender.indexOfSelectedItem
        guard ReasoningEffort.allCases.indices.contains(row) else { return }
        preferences.effort = ReasoningEffort.allCases[row]
        preferencesDidChange()
    }

    private func preferencesDidChange() {
        let providers = [preferences.provider] + preferences.fallbackTargets.map(\.provider)
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
