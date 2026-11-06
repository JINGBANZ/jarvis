#if JARVIS_LIVE_E2E // Debug builds only: see liveE2ESettings in Package.swift
import Foundation
import JarvisCore

/// `observe` must return at once and never call back into coaching, per the auditing port contract.
struct LiveE2EAttemptObserver: CoachingAttemptAuditing {
    let evidence: FileSessionAudit
    let observe: @Sendable (CoachingAttemptAuditEvent) -> Void

    func record(_ event: CoachingAttemptAuditEvent) {
        evidence.record(event)
        observe(event)
    }
}
#endif
