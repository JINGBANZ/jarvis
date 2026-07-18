import AppKit
import JarvisCore

/// The single funnel for user-facing failures. Every error in the app is reported here; severity
/// decides the response — `.fatal` pops a modal alert AND tears the session down (`onFatal`),
/// `.warning` pops the alert but leaves any running session untouched (preflight failures),
/// `.degraded` is logged only. The only place an *error* `NSAlert` is raised (confirmation prompts,
/// e.g. ActivityViewer's clear-history, are a separate concern and don't route here).
///
/// Diagnostics stay in the agent-facing `JarvisLog`/`jlog` debug log; this type owns *user-facing
/// surfacing + session-lifecycle consequence*. `report(_:)` is `nonisolated` so any
/// thread (the capture IOProc, a URLSession delegate) can call it directly; it hops to the main actor.
@MainActor
final class ErrorReporter {
    /// Invoked for a `.fatal` error (on the main actor) to stop the running session and correct the
    /// menu. Wired by `AppDelegate` once the menu bar exists.
    var onFatal: (() -> Void)?

    nonisolated func report(_ error: UserFacingError) {
        Task { @MainActor in self.present(error) }
    }

    private func present(_ error: UserFacingError) {
        jlog("Jarvis: \(error.severity) — \(error.title): \(error.message)")  // diagnostics still go to JarvisLog
        if error.severity.stopsSession { onFatal?() }
        guard error.severity.showsAlert else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = error.title
        alert.informativeText = error.message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
