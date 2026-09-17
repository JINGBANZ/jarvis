#if JARVIS_LIVE_E2E // Debug builds only: see liveE2ESettings in Package.swift
import AppKit
import Foundation
import JarvisCore

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
        // Remove speech even on abort. No marker follows terminate, so the log is the only report.
        do {
            try runner.removeGeneratedAudio()
        } catch {
            jlog("Jarvis live e2e: could not remove synthesized speech: \(error)")
        }
    }
}
#endif
