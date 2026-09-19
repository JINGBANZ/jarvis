import AppKit
import Foundation
import JarvisCore

@MainActor
final class TranscriptionBenchmarkAppDelegate: NSObject, NSApplicationDelegate {
    private let options: TranscriptionBenchmarkOptions
    private var runTask: Task<Void, Never>?

    init(options: TranscriptionBenchmarkOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited) // ghost-mode-allowed: hidden explicit benchmark process
        runTask = Task { [options] in
            do {
                try await TranscriptionBenchmarkRunner(options: options).run()
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
