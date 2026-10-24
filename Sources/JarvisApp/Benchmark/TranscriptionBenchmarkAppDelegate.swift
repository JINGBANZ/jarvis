import AppKit
import Foundation
import JarvisProcess
import JarvisCore

@MainActor
final class TranscriptionBenchmarkAppDelegate: NSObject, NSApplicationDelegate {
    private let options: TranscriptionBenchmarkOptions
    private var runTask: Task<Void, Never>?

    private let launcher: any ProcessLaunching

    init(options: TranscriptionBenchmarkOptions, launcher: any ProcessLaunching) {
        self.launcher = launcher
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited) // ghost-mode-allowed: hidden explicit benchmark process
        runTask = Task { [options, launcher] in
            do {
                try await TranscriptionBenchmarkRunner(options: options, launcher: launcher).run()
                // Written only after runner defers have stopped capture and removed synthetic audio.
                try TranscriptionBenchmarkFiles.createMarker(
                    named: "benchmark-finished", in: options.outputDirectory)
            } catch {
                jlog("Jarvis transcription benchmark failed: \(error)")
                TranscriptionBenchmarkFiles.writeFailure(
                    String(describing: error), to: options.outputDirectory)
            }
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        runTask?.cancel()
    }
}
