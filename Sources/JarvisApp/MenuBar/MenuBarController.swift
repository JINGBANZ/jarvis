import AppKit

/// Menu-bar status item: start/stop, a "Settings…" item, and a session interjection counter.
/// Exactly two states: ⚪️ stopped and 🟢 running. All settings (API key, overlay appearance, the
/// dev activity log) live in the unified Settings window, opened via `onOpenSettings`.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let counterItem = NSMenuItem(title: "Interjections: 0", action: nil, keyEquivalent: "")
    private let startStopItem = NSMenuItem(title: "Start Jarvis", action: nil, keyEquivalent: "s")
    private var interjections = 0
    /// Whether the listen/coach pipeline is currently running.
    private(set) var isRunning = false

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

    /// The single source of truth for running state.
    func setRunning(_ running: Bool) {
        isRunning = running
        refreshUI()
    }

    @objc private func openSettings() { onOpenSettings?() }

    @objc private func toggleStartStop() {
        if isRunning {
            onStop?()
            setRunning(false)
        } else {
            setRunning(onStart?() ?? false)
        }
    }

    /// Single source of truth for the status title and the start/stop label.
    private func refreshUI() {
        startStopItem.title = isRunning ? "Stop Jarvis" : "Start Jarvis"
        statusItem.button?.title = isRunning ? "🟢 Jarvis" : "⚪️ Jarvis"
    }
}
