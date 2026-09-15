import AppKit
import JarvisCore

/// The live e2e delegate when `--live-e2e` was passed, otherwise nil. The mode is compiled only into
/// debug builds (`JARVIS_LIVE_E2E` in Package.swift), so a release app has no such mode to select.
@MainActor
private func liveE2EDelegate() -> (any NSApplicationDelegate)? {
    #if JARVIS_LIVE_E2E
    guard LiveE2EOptions.isRequested else { return nil }
    // The mode coaches with the saved key and signed-in CLIs, under this app's screen grant, on
    // paths its caller names. Only the development app, which a developer built, accepts that.
    guard Bundle.main.infoDictionary?["JarvisDevelopmentBuild"] as? Bool == true else {
        fputs("Jarvis live e2e: only the development build runs live e2e scenarios\n", stderr)
        exit(2)
    }
    do {
        return try LiveE2EAppDelegate(options: LiveE2EOptions())
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
