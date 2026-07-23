import AppKit
import JarvisCore

/// The single funnel for user-facing failures. Severity decides the lifecycle consequence; the
/// call-site context decides whether a startup alert is permitted. Runtime failures never activate
/// the app or present UI, even when they stop the session. The only place an *error* `NSAlert` is
/// raised (confirmation prompts, e.g. ActivityViewer's clear-history, are a separate concern and
/// don't route here).
///
/// Diagnostics stay in the agent-facing `JarvisLog`/`jlog` debug log; this type owns *user-facing
/// surfacing + session-lifecycle consequence*. `report(_:)` is `nonisolated` so any
/// thread (the capture IOProc, a URLSession delegate) can call it directly; it hops to the main actor.
@MainActor
final class ErrorReporter {
    /// Invoked for an error whose severity stops the session (on the main actor), correcting the
    /// menu without requiring a modal alert. Wired by `AppDelegate` once the menu bar exists.
    var onFatal: (() -> Void)?

    nonisolated func report(_ error: UserFacingError,
                            context: UserFacingError.PresentationContext) {
        Task { @MainActor in self.reportImmediately(error, context: context) }
    }

    /// Deliver synchronously when the caller is already on the main actor. This keeps a guarded
    /// runtime failure atomic with its lifecycle consequence instead of introducing another queued
    /// task in which a newer provider configuration could be stopped.
    func reportImmediately(_ error: UserFacingError,
                           context: UserFacingError.PresentationContext) {
        present(error, context: context)
    }

    private func present(_ error: UserFacingError,
                         context: UserFacingError.PresentationContext) {
        jlog("Jarvis: \(error.severity) — \(error.title): \(error.message)")  // diagnostics still go to JarvisLog
        if error.severity.stopsSession { onFatal?() }
        guard error.severity.showsAlert(in: context) else { return }
        NSApp.activate(ignoringOtherApps: true) // ghost-mode-allowed: explicit startup failure
        let alert = NSAlert() // ghost-mode-allowed: explicit startup failure
        alert.messageText = error.title
        alert.informativeText = error.message
        alert.alertStyle = .warning
        alert.runModal() // ghost-mode-allowed: explicit startup failure
    }
}
