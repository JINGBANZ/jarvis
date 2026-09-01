import Foundation

/// Serializes every test — across suites — that installs a `JarvisLog.attach`/`detach`
/// process-global attachment.
///
/// `JarvisLog`'s attachment is one process-global slot (`Sources/JarvisCore/Diagnostics/Log.swift`),
/// and each suite that installs it — `DiagnosticEvidenceTests`, `CoachDriverPipelineTests`,
/// `CaptureHeartbeatTests`, and `SessionAuditIsolationTests` (via `CoachingParityHarness`) — is
/// individually `@Suite(.serialized)`. That only serializes cases *within* one suite; swift-testing
/// still runs distinct suites concurrently by default, so two suites' tests could otherwise race to
/// attach and silently mis-attribute each other's diagnostics.
///
/// An `actor` (suspending, not thread-blocking) rather than a `DispatchSemaphore`: a semaphore's
/// `wait()` blocks the calling thread outright, and every call site here holds the lock across real
/// `await` points (`evidence.close()`, `waitForDebugLine`, `CoachingParityHarness.run`'s own async
/// work) — blocking a Swift Concurrency cooperative-pool thread for that long risks starving the
/// whole pool on a CI runner with few cores, which does not grow the pool to compensate for a
/// synchronously blocked thread the way GCD would.
actor JarvisLogAttachmentLock {
    static let shared = JarvisLogAttachmentLock()

    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        guard waiters.isEmpty else {
            waiters.removeFirst().resume()
            return
        }
        isHeld = false
    }

    /// Run `body` with exclusive ownership of the process-global attachment, releasing on every
    /// path — including a thrown error — so a failed assertion can never leave the lock stuck for
    /// the rest of the run.
    static func withExclusiveAttachment<T>(_ body: () async throws -> T) async rethrows -> T {
        await shared.acquire()
        do {
            let result = try await body()
            await shared.release()
            return result
        } catch {
            await shared.release()
            throw error
        }
    }
}
