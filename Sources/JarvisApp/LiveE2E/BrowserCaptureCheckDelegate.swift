#if JARVIS_LIVE_E2E
import AppKit
import ApplicationServices
import JarvisCore

/// Explicit local smoke check: uses the signed app's production capture and TCC identity without
/// starting audio or a brain provider. The operator owns the browser and any scrolling.
@MainActor
final class BrowserCaptureCheckDelegate: NSObject, NSApplicationDelegate {
    private let options: LiveE2EOptions

    init(options: LiveE2EOptions) { self.options = options }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited) // ghost-mode-allowed: explicit hidden capture test
        Task {
            runCheck()
            NSApp.terminate(nil)
        }
    }

    private func runCheck() {
        do {
            try TranscriptionBenchmarkFiles.prepareOutputDirectory(options.outputDirectory)
            let expectation = try BrowserCaptureExpectation.decode(Data(contentsOf: options.scenarioURL))
            guard CGPreflightScreenCaptureAccess(), AXIsProcessTrusted() else {
                try finish("blocked", reasons: ["Screen Recording and Accessibility grants are required."])
                return
            }
            guard let front = NSWorkspace.shared.frontmostApplication,
                  front.bundleIdentifier == "com.google.Chrome" else {
                try finish("blocked", reasons: ["Bring the authorized fixture to the front in Google Chrome."])
                return
            }
            let capture = WindowScopedScreenCapture(captureDirectory: options.outputDirectory)
            let abort = options.outputDirectory.appendingPathComponent("abort")
            guard !FileManager.default.fileExists(atPath: abort.path) else {
                try finish("fail", reasons: ["Capture check cancelled before capture."])
                return
            }
            // Capture is synchronous, so cancellation must run off the main actor. The production
            // runner owns the helper PID and proves its transient JPEG is removed before returning.
            let deadline = Date().addingTimeInterval(25)
            let cancellation = Task.detached {
                while !Task.isCancelled {
                    if Date() >= deadline || FileManager.default.fileExists(atPath: abort.path) {
                        // Repeat until capture returns: cancellation can arrive while AX is
                        // priming, before the screenshot helper has registered its command.
                        capture.cancelCapture()
                    }
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { return }
                }
            }
            defer { cancellation.cancel() }
            let snapshot = capture.capture(ScreenCaptureSelection(
                scope: .activeWindow, explicitDisplay: nil, browserTextEnabled: true))
            var failures = expectation.failures(in: snapshot)
            if Date() >= deadline || FileManager.default.fileExists(atPath: abort.path) {
                failures.append("Capture check cancelled or timed out.")
            }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != front.processIdentifier {
                failures.append("The foreground application changed during capture.")
            }
            try finish(failures.isEmpty ? "pass" : "fail", reasons: failures)
        } catch {
            // Report no captured content or arbitrary error payload; absence of a result also fails
            // the shell checker if the output itself is unwritable.
            try? finish("fail", reasons: ["Capture check setup or result writing failed."])
        }
    }

    private func finish(_ status: String, reasons: [String]) throws {
        let result = (["CHROME \(status)"] + reasons).joined(separator: "\n") + "\n"
        try TranscriptionBenchmarkFiles.writeText(
            result, named: "capture-check.txt", to: options.outputDirectory)
        try TranscriptionBenchmarkFiles.createMarker(
            named: "capture-check-finished", in: options.outputDirectory)
    }
}
#endif
