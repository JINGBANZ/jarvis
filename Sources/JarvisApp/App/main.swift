import AppKit
import JarvisCore

let app = NSApplication.shared
let delegate: any NSApplicationDelegate
if LiveE2EOptions.isRequested {
    // The mode coaches with the saved key and signed-in CLIs, under this app's screen grant, on
    // paths its caller names. Only the development app, which a developer built, accepts that.
    guard Bundle.main.infoDictionary?["JarvisDevelopmentBuild"] as? Bool == true else {
        fputs("Jarvis live e2e: only the development build runs live e2e scenarios\n", stderr)
        exit(2)
    }
    do {
        delegate = try LiveE2EAppDelegate(options: LiveE2EOptions())
    } catch {
        fputs("Jarvis live e2e: \(error)\n", stderr)
        exit(2)
    }
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
