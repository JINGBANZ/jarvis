#if JARVIS_LIVE_E2E // Debug builds only: see liveE2ESettings in Package.swift
import Foundation
import JarvisCore

/// Records every coaching-attempt event into the session's evidence, then hands a copy to the live
/// e2e runner, which paces its steps on attempts starting and finishing rather than on timers.
///
/// The port contract holds: both calls return immediately, and the copy only enters an
/// `AsyncStream`, so nothing here calls back into coaching.
struct LiveE2EAttemptObserver: CoachingAttemptAuditing {
    let evidence: FileSessionAudit
    let observe: @Sendable (CoachingAttemptAuditEvent) -> Void

    func record(_ event: CoachingAttemptAuditEvent) {
        evidence.record(event)
        observe(event)
    }
}
#endif
