import AppKit
import JarvisCore

/// Menu-bar status item: Start/Stop, Settings, Check for Updates, Quit, then the build version —
/// every command in the standard icon+title format (see `NSMenuItem+Standard.swift`). It renders the
/// same overall `JarvisReadiness.Status` as Activity; no connection/capture policy is duplicated in
/// this AppKit adapter.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let startStopItem = NSMenuItem.standard("Start Jarvis", symbol: "play.fill", keyEquivalent: "s")
    /// Nil in a development bundle, which carries no update feed — see `UpdateController`.
    /// Not private: `MenuBarController+MenuDelegate.swift` refreshes it when the menu opens.
    let updateItem: NSMenuItem?
    private(set) var status: JarvisReadiness.Status = .stopped
    /// Whether a pipeline exists, including its startup/reconnect windows.
    var isRunning: Bool { status.keepsSessionActive }

    /// Fired when the user asks to start the pipeline. Returns `true` if it actually started.
    var onStart: (() -> Bool)?
    /// Fired when the user asks to stop the pipeline.
    var onStop: (() -> Void)?
    /// Fired when the user picks "Settings…". Opens the unified Settings window.
    var onOpenSettings: (() -> Void)?
    /// Fired when the user picks "Check for Updates". Answers whether Sparkle can start a check, so
    /// the item can render its own availability without this adapter importing Sparkle.
    /// Not private for the same reason as `updateItem`.
    let updateAvailability: (() -> Bool)?
    private let onCheckForUpdates: (() -> Void)?

    /// - Parameters:
    ///   - updateAvailability: whether an update check can start right now, or nil when this build
    ///     has no updater at all — the item is then omitted rather than shown disabled forever.
    ///   - onCheckForUpdates: runs the explicit check.
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
            .standard("Settings…", symbol: "gearshape",
                      action: #selector(openSettings), target: self, keyEquivalent: ","),
        ]
        if let updateItem { menu.items.append(updateItem) }
        menu.items.append(contentsOf: [
            .standard("Quit Jarvis", symbol: "power",
                      action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
            Self.versionItem(),
        ])
        // The item's availability depends on live session state, so resolve it when the menu opens
        // rather than caching it at build time.
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        refreshUI()
    }

    /// Render the Core composition result without independently deriving readiness.
    func setStatus(_ status: JarvisReadiness.Status) {
        self.status = status
        refreshUI()
    }

    /// The running build's marketing version, so a user reporting an issue can read it off the menu
    /// without opening Settings. `Resources/Info.plist` is the single source (release-please rewrites
    /// it), and both the release and the development bundle carry it.
    ///
    /// The one item that skips the icon+title command format: it is a non-interactive footer caption,
    /// and centering needs the whole item width. A plain title would be drawn after the leading
    /// state/image column and centered only within what remains, so the caption is a custom view —
    /// AppKit sizes an item view to the menu's width, and the label spans it.
    private static func versionItem() -> NSMenuItem {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let label = NSTextField(labelWithString: version.map { "v\($0)" } ?? "version unknown")
        label.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .disabledControlTextColor
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
        // The menu disables automatic validation so the update item can resolve its own availability
        // when the menu opens, so this caption states the inert state AppKit would otherwise infer
        // from its missing action.
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

    /// Single source of truth for the status icon and the start/stop item.
    private func refreshUI() {
        startStopItem.applyStandard(title: status.keepsSessionActive ? "Stop Jarvis" : "Start Jarvis",
                                    symbol: status.keepsSessionActive ? "stop.fill" : "play.fill")
        guard let button = statusItem.button else { return }
        button.image = status.iconSignal.map(MenuBarIcon.live) ?? MenuBarIcon.stopped
        button.title = ""
        button.toolTip = status.menuDescription
    }
}

private extension JarvisReadiness.Status {
    var keepsSessionActive: Bool {
        switch self {
        case .checking, .recovering, .ready:
            true
        case .blocked, .stopped:
            false
        }
    }

    /// How the status item renders this status, or nil for the stopped glyph. Startup and recovery
    /// both light the icon: they are sessions in progress, and rendering them as stopped told the
    /// user Jarvis was off for the several seconds it takes to come up.
    var iconSignal: MenuBarIcon.Signal? {
        switch self {
        case .checking, .recovering: .working
        case .ready: .ready
        case .blocked: .blocked
        case .stopped: nil
        }
    }

    var menuDescription: String {
        switch self {
        case .checking(let requirement):
            "Jarvis is starting — \(requirement.menuDescription)"
        case .blocked(let blocker):
            "Jarvis is blocked — \(blocker.menuDescription)"
        case .recovering(let requirement, let attempt):
            if let attempt {
                "Jarvis is recovering — \(requirement.menuDescription), attempt \(attempt)"
            } else {
                "Jarvis is recovering — \(requirement.menuDescription)"
            }
        case .ready(.full):
            "Jarvis is ready"
        case .ready(.microphoneOnly):
            "Jarvis is ready — microphone only"
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
