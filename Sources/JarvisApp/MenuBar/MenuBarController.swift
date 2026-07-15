import AppKit

/// Menu-bar status item: start/stop, live connection health, Settings, and the session interjection
/// counter. The icon is full-colour only while mic transcription is actually ready; starting and
/// reconnecting stay visibly distinct from a healthy listening session.
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

        var statusText: String {
            switch self {
            case .stopped: "Status: Stopped"
            case .starting: "Status: Connecting…"
            case .listening: "Status: Listening"
            case .reconnecting(let attempt): "Status: Reconnecting microphone (attempt \(attempt))…"
            case .systemAudioConnecting: "Status: Listening — system audio connecting"
            case .microphoneOnly: "Status: Listening — system audio unavailable"
            }
        }

        var isMicReady: Bool {
            self == .listening || self == .systemAudioConnecting || self == .microphoneOnly
        }
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let connectionItem = NSMenuItem(title: "Status: Stopped", action: nil, keyEquivalent: "")
    private let counterItem = NSMenuItem(title: "Interjections: 0", action: nil, keyEquivalent: "")
    private let startStopItem = NSMenuItem(title: "Start Jarvis", action: nil, keyEquivalent: "s")
    private var interjections = 0
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
        let menu = NSMenu()
        startStopItem.target = self
        startStopItem.action = #selector(toggleStartStop)
        menu.addItem(startStopItem)
        menu.addItem(connectionItem)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(counterItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Jarvis", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
        refreshUI()
    }

    func noteSpoke() {
        interjections += 1
        counterItem.title = "Interjections: \(interjections)"
    }

    /// Reset the per-session interjection count (called on each Start).
    func resetCounter() {
        interjections = 0
        counterItem.title = "Interjections: 0"
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

    /// Single source of truth for the status icon and the start/stop label.
    private func refreshUI() {
        startStopItem.title = state.isActive ? "Stop Jarvis" : "Start Jarvis"
        connectionItem.title = state.statusText
        guard let button = statusItem.button else { return }
        button.image = state.isMicReady ? MenuBarIcon.running : MenuBarIcon.stopped
        button.title = ""
    }
}
