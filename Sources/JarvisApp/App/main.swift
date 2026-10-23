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
        return try LiveE2EAppDelegate(options: LiveE2EOptions())
    } catch {
        fputs("Jarvis live e2e: \(error)\n", stderr)
        exit(2)
    }
    #else
    return nil
    #endif
}

@MainActor
private func capturePrivacyDelegate() -> (any NSApplicationDelegate)? {
    #if JARVIS_LIVE_E2E
    guard CommandLine.arguments.contains("--capture-privacy") else { return nil }
    do { return try CapturePrivacyAppDelegate() } catch {
        fputs("Jarvis capture privacy: \(error)\n", stderr)
        exit(2)
    }
    #else
    return nil
    #endif
}

@MainActor
private func referenceHarnessDelegate() -> (any NSApplicationDelegate)? {
    #if JARVIS_LIVE_E2E
    guard CommandLine.arguments.contains("--reference-harness") else { return nil }
    do { return try ReferenceHarnessAppDelegate() } catch {
        fputs("Reference harness: invalid development invocation\n", stderr)
        exit(2)
    }
    #else
    return nil
    #endif
}

@MainActor
private func settingsHarnessDelegate() -> (any NSApplicationDelegate)? {
    #if JARVIS_LIVE_E2E
    guard CommandLine.arguments.contains("--settings-harness") else { return nil }
    do { return try SettingsHarnessAppDelegate() } catch {
        fputs("Settings harness: invalid development invocation\n", stderr)
        exit(2)
    }
    #else
    return nil
    #endif
}

do { try TestCommandOwnership.registerApplication() } catch {
    fputs("Test command ownership registration failed\n", stderr)
    exit(70)
}

let app = NSApplication.shared
let delegate: any NSApplicationDelegate
if let settings = settingsHarnessDelegate() {
    delegate = settings
} else if let references = referenceHarnessDelegate() {
    delegate = references
} else if let capturePrivacy = capturePrivacyDelegate() {
    delegate = capturePrivacy
} else if let liveE2E = liveE2EDelegate() {
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
