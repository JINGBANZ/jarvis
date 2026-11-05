import Foundation

/// `@unchecked Sendable`: `lock` guards the session's shared, irreversible cleanup failure.
final class ScreenCaptureCleanupState: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false

    var hasFailed: Bool { lock.withLock { failed } }

    func recordFailure() {
        lock.withLock { failed = true }
    }
}
