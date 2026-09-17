import AppKit
import JarvisCore

@MainActor
final class ErrorReporter {
    var onFatal: ((SessionEndReason) -> Void)?

    nonisolated func report(_ error: UserFacingError,
                            context: UserFacingError.PresentationContext) {
        Task { @MainActor in self.reportImmediately(error, context: context) }
    }

    /// Synchronous, so the session stop can't run in a later task after a newer provider
    /// configuration has started.
    func reportImmediately(_ error: UserFacingError,
                           context: UserFacingError.PresentationContext) {
        present(error, context: context)
    }

    private func present(_ error: UserFacingError,
                         context: UserFacingError.PresentationContext) {
        jlog("Jarvis: \(error.severity) — \(error.title): \(error.message)")
        if error.severity.stopsSession {
            onFatal?(error.sessionEndReason ?? .unexpectedError(detail: error.message))
        }
        guard error.severity.showsAlert(in: context) else { return }
        NSApp.activate(ignoringOtherApps: true) // ghost-mode-allowed: explicit startup failure
        let alert = NSAlert() // ghost-mode-allowed: explicit startup failure
        alert.messageText = error.title
        alert.informativeText = error.message
        alert.alertStyle = .warning
        alert.runModal() // ghost-mode-allowed: explicit startup failure
    }
}
