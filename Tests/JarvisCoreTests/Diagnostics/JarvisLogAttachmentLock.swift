import Foundation

/// Serializes every test — across suites — that installs a `JarvisLog.attach`/`detach`
/// process-global attachment.
///
/// `JarvisLog`'s attachment is one process-global slot (`Sources/JarvisCore/Diagnostics/Log.swift`),
/// and each suite that installs it — `DiagnosticEvidenceTests`, `CoachDriverPipelineTests`,
/// `CaptureHeartbeatTests`, and `SessionAuditIsolationTests` (via `CoachingParityHarness`) — is
/// individually `@Suite(.serialized)`. That only serializes cases *within* one suite; swift-testing
/// still runs distinct suites concurrently by default, so two suites' tests could otherwise race to
/// attach and silently mis-attribute each other's diagnostics — the cause of an intermittent
/// `queue_overflow` miscount in `DiagnosticEvidenceTests`. Acquire this around every attach...detach
/// span so concurrent suites serialize around the shared slot instead of racing for it.
enum JarvisLogAttachmentLock {
    private static let semaphore = DispatchSemaphore(value: 1)

    static func acquire() { semaphore.wait() }
    static func release() { semaphore.signal() }
}
