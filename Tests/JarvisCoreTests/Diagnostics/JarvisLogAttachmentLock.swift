import Foundation

/// Serializes the process-global `JarvisLog.attach` across suites. Other suites' `jlog` still lands
/// in the attachment, so attached tests assert only presence or absence, never exact counts. An
/// actor, not a semaphore: holders await while locked, and a blocked pool thread can starve CI.
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
