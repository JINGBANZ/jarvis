import AppKit

/// Menu-bar status item: start/stop, a "Settings…" item, and a session interjection counter.
/// Two states, shown as the robot emoji icon: desaturated (black-and-white) when stopped, full
/// colour when running. All settings (API key, overlay appearance, the dev activity log) live in
/// the unified Settings window, opened via `onOpenSettings`.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let counterItem = NSMenuItem(title: "Interjections: 0", action: nil, keyEquivalent: "")
    private let startStopItem = NSMenuItem(title: "Start Jarvis", action: nil, keyEquivalent: "s")
    /// Toggles the persistent response box; its title flips between "Show"/"Hide" to mirror the state,
    /// matching the Start/Stop convention above.
    private let responsesItem = NSMenuItem(title: "Show Responses", action: nil, keyEquivalent: "")
    private var interjections = 0
    /// Whether the listen/coach pipeline is currently running.
    private(set) var isRunning = false

    /// Fired when the user asks to start the pipeline. Returns `true` if it actually started.
    var onStart: (() -> Bool)?
    /// Fired when the user asks to stop the pipeline.
    var onStop: (() -> Void)?
    /// Fired when the user picks "Settings…". Opens the unified Settings window.
    var onOpenSettings: (() -> Void)?
    /// Fired when the user picks "Show Responses". Toggles the response-history window.
    var onToggleResponses: (() -> Void)?

    override init() {
        super.init()
        let menu = NSMenu()
        startStopItem.target = self
        startStopItem.action = #selector(toggleStartStop)
        menu.addItem(startStopItem)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        responsesItem.target = self
        responsesItem.action = #selector(toggleResponses)
        menu.addItem(responsesItem)
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

    /// The single source of truth for running state.
    func setRunning(_ running: Bool) {
        isRunning = running
        refreshUI()
    }

    @objc private func openSettings() { onOpenSettings?() }

    @objc private func toggleResponses() { onToggleResponses?() }

    /// Flip the toggle's title to mirror whether the response box is currently shown.
    func setResponsesShown(_ shown: Bool) {
        responsesItem.title = shown ? "Hide Responses" : "Show Responses"
    }

    @objc private func toggleStartStop() {
        if isRunning {
            onStop?()
            setRunning(false)
        } else {
            setRunning(onStart?() ?? false)
        }
    }

    /// Single source of truth for the status icon and the start/stop label.
    private func refreshUI() {
        startStopItem.title = isRunning ? "Stop Jarvis" : "Start Jarvis"
        guard let button = statusItem.button else { return }
        button.image = isRunning ? MenuBarIcon.running : MenuBarIcon.stopped
        button.title = ""
    }
}
