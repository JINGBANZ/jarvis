import AppKit

/// Menu-bar status item: Start/Stop, Settings, Quit — every item in the standard icon+title format
/// (see `NSMenuItem+Standard.swift`). The icon is full-colour only while mic transcription is
/// actually ready; starting and reconnecting stay visibly distinct from a healthy listening session.
@MainActor
final class MenuBarController: NSObject {
    enum State: Equatable {
        case stopped
        case starting
        case listening
        case reconnecting(attempt: Int)
        case systemAudioConnecting
        case microphoneOnly

        var isActive: Bool { self != .stopped }

        var isMicReady: Bool {
            self == .listening || self == .systemAudioConnecting || self == .microphoneOnly
        }
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let startStopItem = NSMenuItem.standard("Start Jarvis", symbol: "play.fill", keyEquivalent: "s")
    private(set) var state: State = .stopped
    /// Whether a pipeline exists, including its startup/reconnect windows.
    var isRunning: Bool { state.isActive }

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

    /// The single source of truth for pipeline and mic-connection health.
    func setState(_ state: State) {
        self.state = state
        refreshUI()
    }

    @objc private func openSettings() { onOpenSettings?() }

    @objc private func toggleStartStop() {
        if state.isActive {
            onStop?()
            setState(.stopped)
        } else {
            _ = onStart?()
        }
    }

    /// Single source of truth for the status icon and the start/stop item.
    private func refreshUI() {
        startStopItem.applyStandard(title: state.isActive ? "Stop Jarvis" : "Start Jarvis",
                                    symbol: state.isActive ? "stop.fill" : "play.fill")
        guard let button = statusItem.button else { return }
        button.image = state.isMicReady ? MenuBarIcon.running : MenuBarIcon.stopped
        button.title = ""
    }
}
