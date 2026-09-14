import AppKit
import JarvisCore

let app = NSApplication.shared
let delegate: any NSApplicationDelegate
if LiveE2EOptions.isRequested {
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
