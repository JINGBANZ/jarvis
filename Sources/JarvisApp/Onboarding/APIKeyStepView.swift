import AppKit
import JarvisCore

// Design: wiki/architecture.md#onboarding
@MainActor
final class APIKeyStepView: NSView, NSTextFieldDelegate {
    var onFinished: (() -> Void)?

    private var step = OnboardingAPIKeyStep(credential: .openAIAPIKey)
    private let keyStore: FileSecretStore
    private let brainPreferences: BrainPreferences
    private let transcriptionPreferences: TranscriptionPreferences
    private var tiles: [ProviderTileView] = []
    private let fieldLabel = NSTextField(labelWithString: "")
    private let field = NSSecureTextField()
    private var createLink: ClosureButton?
    private var shell: OnboardingStepView?
    private var checkTask: Task<Void, Never>?

    init(
        keyStore: FileSecretStore,
        brainPreferences: BrainPreferences,
        transcriptionPreferences: TranscriptionPreferences,
        step index: Int, of count: Int,
        onQuit: @escaping () -> Void
    ) {
        self.keyStore = keyStore
        self.brainPreferences = brainPreferences
        self.transcriptionPreferences = transcriptionPreferences
        super.init(frame: NSRect(origin: .zero, size: OnboardingStepView.size))

        tiles = Credential.allCases.map { credential in
            ProviderTileView(
                credential: credential,
                thinks: Onboarding.brainModel(for: credential).displayName,
                listens: Onboarding.transcriptionModelName(for: credential, in: transcriptionPreferences),
                onChoose: { [weak self] chosen in
                    self?.step.select(chosen)
                    self?.render()
                })
        }
        let shell = OnboardingStepView(
            lit: [.brain, .ear],
            title: "Hi, I’m Jarvis.",
            lede: "Pick who powers my brain and ears. You can switch later in Settings.",
            body: makeBody(), step: index, of: count, onQuit: onQuit,
            onPrimary: { [weak self] in self?.continuePressed() })
        shell.frame = bounds
        shell.autoresizingMask = [.width, .height]
        addSubview(shell)
        self.shell = shell
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var initialFirstResponder: NSView { field }

    func stop() {
        checkTask?.cancel()
        checkTask = nil
    }

    func controlTextDidChange(_ notification: Notification) {
        step.edit(field.stringValue)
        render()
    }

    private func makeBody() -> NSView {
        let body = NSView()
        let tileRow = NSStackView(views: tiles)
        tileRow.orientation = .horizontal
        tileRow.distribution = .fillEqually
        tileRow.spacing = 12

        let link = ClosureButton(title: "") { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.step.credential.keyPageURL) // ghost-mode-allowed: explicit click on onboarding's Create one link, before any session exists
        }
        link.isBordered = false
        link.attributedTitle = NSAttributedString(string: "Create one ↗", attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: OnboardingTheme.link,
        ])
        createLink = link

        fieldLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        fieldLabel.textColor = OnboardingTheme.text
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        field.identifier = NSUserInterfaceItemIdentifier("onboarding-key-field")

        for view in [tileRow, fieldLabel, link, field] {
            view.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(view)
        }
        // Tiles inset their card 3 pt for the chosen ring, so the field lines up with the cards.
        NSLayoutConstraint.activate([
            tileRow.topAnchor.constraint(equalTo: body.topAnchor),
            tileRow.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            tileRow.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            tileRow.heightAnchor.constraint(equalToConstant: ProviderTileView.height),
            fieldLabel.topAnchor.constraint(equalTo: tileRow.bottomAnchor, constant: 16),
            fieldLabel.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 3),
            link.firstBaselineAnchor.constraint(equalTo: fieldLabel.firstBaselineAnchor),
            link.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -3),
            field.topAnchor.constraint(equalTo: fieldLabel.bottomAnchor, constant: 6),
            field.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 3),
            field.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -3),
            field.heightAnchor.constraint(equalToConstant: 28),
            field.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])
        return body
    }

    private func render() {
        let credential = step.credential
        let checking = step.phase == .checking
        for tile in tiles {
            tile.isChosen = tile.credential == credential
            tile.isEnabled = !checking
        }
        fieldLabel.stringValue = "\(credential.vendorName) API key"
        field.placeholderString = credential.placeholderHint
        field.setAccessibilityLabel("\(credential.vendorName) API key")
        field.isEnabled = !checking
        createLink?.setAccessibilityLabel("Create a \(credential.vendorName) key")
        shell?.setNote(step.note, warning: step.noteTone == .warning)
        shell?.setPrimary(title: step.primaryTitle, enabled: step.canContinue)
    }

    private func continuePressed() {
        guard let effect = step.continuePressed() else { return }
        render()
        perform(effect)
    }

    private func perform(_ effect: OnboardingAPIKeyStep.Effect) {
        switch effect {
        case .check(let credential, let key):
            checkTask?.cancel()
            checkTask = Task { [weak self] in
                let verdict = await CredentialVerifier().check(credential, key: key)
                guard !Task.isCancelled, let self else { return }
                let next = self.step.receive(verdict)
                self.render()
                if let next {
                    self.perform(next)
                } else {
                    self.window?.makeFirstResponder(self.field)
                }
            }
        case .save(let credential, let key):
            guard keyStore.setApiKey(key, for: credential) else {
                jlog("Jarvis: onboarding couldn't write the \(credential.rawValue) key file")
                step.saveFailed()
                render()
                return
            }
            Onboarding.adopt(credential, brain: brainPreferences, transcription: transcriptionPreferences)
            jlog("Jarvis: onboarding saved the \(credential.rawValue) key")
            onFinished?()
        }
    }
}
