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
                    options.mode == .microphone ? Self.microphoneFailureMessage(error)
                        : String(describing: error), to: options.outputDirectory)
            }
            NSApp.terminate(nil)
        }
    }

    private static func microphoneFailureMessage(_ error: any Error) -> String {
        if let capture = error as? MicrophoneBenchmarkCapture.Failure { return capture.description }
        if let benchmark = error as? TranscriptionBenchmarkRunner.Failure {
            switch benchmark {
            case .apiKeyUnavailable: return "OpenAI credentials are unavailable."
            case .benchmarkAborted: return "Microphone benchmark cancelled."
            default: break
            }
        }
        return "Microphone benchmark did not complete; no speech was saved."
    }

    func applicationWillTerminate(_ notification: Notification) {
        runTask?.cancel()
    }
}
