import AppKit

let app = NSApplication.shared
let delegate: any NSApplicationDelegate
if TranscriptionBenchmarkOptions.isRequested {
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
