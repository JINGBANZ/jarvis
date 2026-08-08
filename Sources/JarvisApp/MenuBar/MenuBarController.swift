import AppKit
import JarvisCore

/// Menu-bar status item: Start/Stop, Settings, Quit — every item in the standard icon+title format
/// (see `NSMenuItem+Standard.swift`). It renders the same overall `JarvisReadiness.Status` as Activity;
/// no connection/capture policy is duplicated in this AppKit adapter.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let startStopItem = NSMenuItem.standard("Start Jarvis", symbol: "play.fill", keyEquivalent: "s")
    private(set) var status: JarvisReadiness.Status = .stopped
    /// Whether a pipeline exists, including its startup/reconnect windows.
    var isRunning: Bool { status.keepsSessionActive }

    /// Fired when the user asks to start the pipeline. Returns `true` if it actually started.
    var onStart: (() -> Bool)?
    /// Fired when the user asks to stop the pipeline.
    var onStop: (() -> Void)?
    /// Fired when the user picks "Settings…". Opens the unified Settings window.
    var onOpenSettings: (() -> Void)?

    override init() {
        super.init()
        startStopItem.target = self
        startStopItem.action = #selector(toggleStartStop)
        let menu = NSMenu()
        menu.items = [
            startStopItem,
            .standard("Settings…", symbol: "gearshape",
                      action: #selector(openSettings), target: self, keyEquivalent: ","),
            .standard("Quit Jarvis", symbol: "power",
                      action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ]
        statusItem.menu = menu
        refreshUI()
    }

    /// Render the Core composition result without independently deriving readiness.
    func setStatus(_ status: JarvisReadiness.Status) {
        self.status = status
        refreshUI()
    }

    @objc private func openSettings() { onOpenSettings?() }

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
        button.image = status.isReady ? MenuBarIcon.running : MenuBarIcon.stopped
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

    var isReady: Bool {
        if case .ready = self { return true }
        return false
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
