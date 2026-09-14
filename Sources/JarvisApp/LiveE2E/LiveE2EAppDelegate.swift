import AppKit
import Foundation
import JarvisCore

/// The hidden process `scripts/run-live-tests.sh` launches once per scenario, a sibling of the
/// transcription benchmark's delegate. It builds no menu bar, hotkeys, permission gate, Settings, or
/// Activity window; the runner writes its own completion marker or error file.
@MainActor
final class LiveE2EAppDelegate: NSObject, NSApplicationDelegate {
    private let runner: LiveE2ERunner
    private var runTask: Task<Void, Never>?

    init(options: LiveE2EOptions) {
        runner = LiveE2ERunner(options: options)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited) // ghost-mode-allowed: hidden explicit live e2e process
        runTask = Task { [runner] in
            await runner.run()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        runTask?.cancel()
        // A crash-free abort still leaves no synthesized speech behind.
        runner.removeGeneratedAudio()
    }
}
