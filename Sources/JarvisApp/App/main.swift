import AppKit
import JarvisCore

@MainActor
private func liveE2EDelegate() -> (any NSApplicationDelegate)? {
    #if JARVIS_LIVE_E2E
    guard LiveE2EOptions.isRequested else { return nil }
    // Security: the mode spends the saved key, subscriptions, and screen grant on caller-named
    // paths, so only a developer-built app may run it.
    guard Bundle.main.infoDictionary?["JarvisDevelopmentBuild"] as? Bool == true else {
        fputs("Jarvis live e2e: only the development build runs live e2e scenarios\n", stderr)
        exit(2)
    }
    do {
        let options = try LiveE2EOptions()
        if CommandLine.arguments.contains("--browser-capture-check") {
            return BrowserCaptureCheckDelegate(options: options)
        }
        return LiveE2EAppDelegate(options: options)
    } catch {
        fputs("Jarvis live e2e: \(error)\n", stderr)
        exit(2)
    }
    #else
    return nil
    #endif
}

let app = NSApplication.shared
let delegate: any NSApplicationDelegate
if let liveE2E = liveE2EDelegate() {
    delegate = liveE2E
} else if TranscriptionBenchmarkOptions.isRequested {
    do {
        delegate = try TranscriptionBenchmarkAppDelegate(
            options: TranscriptionBenchmarkOptions())
    } catch {
        fputs("Jarvis benchmark: \(error)\n", stderr)
        exit(2)
    }
} else {
    delegate = AppDelegate()
}
app.delegate = delegate
app.run()
