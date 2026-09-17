import AppKit
import JarvisCore

@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let startStopItem = NSMenuItem.standard("Start Jarvis", symbol: "play.fill", keyEquivalent: "s")
    let updateItem: NSMenuItem?
    private(set) var status: JarvisReadiness.Status = .stopped
    var isRunning: Bool { status.keepsSessionActive }

    var onStart: (() -> Bool)?
    var onStop: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    let updateAvailability: (() -> Bool)?
    private let onCheckForUpdates: (() -> Void)?

    /// A nil `updateAvailability` means this build has no updater, so the update item is omitted.
    init(updateAvailability: (() -> Bool)? = nil, onCheckForUpdates: (() -> Void)? = nil) {
        self.updateAvailability = updateAvailability
        self.onCheckForUpdates = onCheckForUpdates
        updateItem = updateAvailability == nil
            ? nil
            : .standard("Check for Updates", symbol: "arrow.down.circle")
        super.init()
        startStopItem.target = self
        startStopItem.action = #selector(toggleStartStop)
        updateItem?.target = self
        updateItem?.action = #selector(checkForUpdates)
        let menu = NSMenu()
        menu.items = [
            startStopItem,
            .standard("Settings", symbol: "gearshape",
                      action: #selector(openSettings), target: self, keyEquivalent: ","),
        ]
        if let updateItem { menu.items.append(updateItem) }
        menu.items.append(contentsOf: [
            .standard("Quit Jarvis", symbol: "power",
                      action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
            Self.buildCaptionItem(),
        ])
        // Manual enabling, so menuNeedsUpdate can set the update item from live session state.
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        refreshUI()
    }

    func setStatus(_ status: JarvisReadiness.Status) {
        self.status = status
        refreshUI()
    }

    /// Dev builds say "Dev": their copied Info.plist names the last release, not the running code.
    /// A custom view, since a plain title centers only in the space after the image column.
    private static func buildCaptionItem() -> NSMenuItem {
        let info = Bundle.main.infoDictionary
        let isDevelopmentBuild = info?["JarvisDevelopmentBuild"] as? Bool == true
        let caption: String
        if isDevelopmentBuild {
            caption = "Dev"
        } else if let version = info?["CFBundleShortVersionString"] as? String {
            caption = "v\(version)"
        } else {
            caption = "version unknown"
        }
        let label = NSTextField(labelWithString: caption)
        label.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = isDevelopmentBuild ? .systemRed : .disabledControlTextColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 22))
        container.autoresizingMask = [.width]
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        let item = NSMenuItem()
        item.view = container
        // autoenablesItems is off, so the missing action no longer disables the item by itself.
        item.isEnabled = false
        return item
    }

    @objc private func openSettings() { onOpenSettings?() }

    @objc private func checkForUpdates() { onCheckForUpdates?() }

    @objc private func toggleStartStop() {
        if status.keepsSessionActive {
            onStop?()
        } else {
            _ = onStart?()
        }
    }

    private func refreshUI() {
        startStopItem.applyStandard(title: status.keepsSessionActive ? "Stop Jarvis" : "Start Jarvis",
                                    symbol: status.keepsSessionActive ? "stop.fill" : "play.fill")
        guard let button = statusItem.button else { return }
        button.image = status.iconSignal.map(MenuBarIcon.live) ?? MenuBarIcon.stopped
        button.title = ""
        button.toolTip = status.menuDescription
        // VoiceOver reads the button, and the glyph is shared by checking and recovering.
        button.setAccessibilityLabel(status.menuDescription)
    }
}

private extension JarvisReadiness.Status {
    var keepsSessionActive: Bool {
        switch self {
        case .checking, .recovering, .ready, .cycleFailed:
            true
        case .blocked, .stopped:
            false
        }
    }

    var iconSignal: MenuBarIcon.Signal? {
        switch self {
        case .checking, .recovering: .preflight
        case .ready: .active
        case .blocked, .cycleFailed: .blocked
        case .stopped: nil
        }
    }

    var menuDescription: String {
        switch self {
        case .checking(let requirement):
            "Jarvis is starting — \(requirement.menuDescription)"
        case .blocked(let blocker):
            "Jarvis is blocked — \(blocker.menuDescription)"
        case .cycleFailed(let provider):
            "\(provider.displayName) coaching failed, still listening"
        case .recovering(.brainResponse(let provider), _):
            "\(provider.displayName) coaching attempt failed — listening continues; retrying"
        case .recovering(let requirement, let attempt):
            if let attempt {
                "Jarvis is recovering — \(requirement.menuDescription), attempt \(attempt)"
            } else {
                "Jarvis is recovering — \(requirement.menuDescription)"
            }
        case .ready(.full):
            "Jarvis is active"
        case .ready(.microphoneOnly):
            "Jarvis is active — microphone only"
        case .stopped:
            "Jarvis is stopped"
        }
    }
}

private extension JarvisReadiness.Requirement {
    var menuDescription: String {
        switch self {
        case .permissions: "checking permissions"
        case .credentials: "checking credentials"
        case .brainPreparation: "preparing the brain provider"
        case .brainResponse(let provider): "waiting for \(provider.displayName)"
        case .transcriptionPreparation: "preparing transcription"
        case .transcriptionEndpoints: "connecting transcription"
        case .capture: "verifying audio capture"
        }
    }
}

private extension JarvisReadiness.Blocker {
    var menuDescription: String {
        switch self {
        case .permissions: "permissions need attention"
        case .credentials: "credentials need attention"
        case .brain: "the brain provider needs attention"
        case .transcription: "transcription needs attention"
        case .endpoint(.microphone): "microphone transcription is unavailable"
        case .endpoint(.system): "system-audio transcription is unavailable"
        case .capture(.microphone): "microphone capture is unavailable"
        case .capture(.system): "system-audio capture is unavailable"
        }
    }
}
