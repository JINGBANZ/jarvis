#if JARVIS_LIVE_E2E // Debug builds only: see liveE2ESettings in Package.swift
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
        runner.terminateProxyHelper()
        // A crash-free abort still leaves no synthesized speech behind. Nothing reads the run after
        // this, and a finished marker was never written for it, so the log is the only place left.
        do {
            try runner.removeGeneratedAudio()
        } catch {
            jlog("Jarvis live e2e: could not remove synthesized speech: \(error)")
        }
    }
}
#endif
