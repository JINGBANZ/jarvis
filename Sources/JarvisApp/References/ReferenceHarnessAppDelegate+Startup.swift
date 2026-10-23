#if JARVIS_LIVE_E2E
import Foundation

extension ReferenceHarnessAppDelegate {
    func referenceStartupStopChecks(home: URL) async throws {
        let queuedHome = home.appendingPathComponent("queued-supervisor")
        let helper = ReferenceHelperSupervisor(bundle: bundle, home: queuedHome,
            launcher: AppProcessComposition.makeLauncher())
        let barrier = ReferenceStartupBarrier()
        helper.beforeLaunchForTesting = { await barrier.wait() }
        let starting = Task { try await helper.start() }
        while !barrier.entered { await Task.yield() }
        var stopFinished = false
        let stopping = Task {
            await helper.stop()
            stopFinished = true
        }
        while !barrier.cancelled { await Task.yield() }
        let drainedBeforeRelease = stopFinished
        barrier.release()
        await stopping.value
        try require(!drainedBeforeRelease, "Stop drains its canceled queued startup before returning")
        do {
            try await starting.value
            throw CocoaError(.coderInvalidValue)
        } catch is CancellationError {}
        try require(helper.processIdentifier == nil && !FileManager.default.fileExists(atPath: queuedHome.path),
                    "Stop alone cancels owned queued startup before any process or helper home is created")

        helper.beforeLaunchForTesting = nil
        try await helper.start()
        let restartedPID = helper.processIdentifier!
        await helper.stop()
        try require(kill(restartedPID, 0) != 0 && errno == ESRCH,
                    "a deliberate restart after Stop owns and reaps its child")

        let handshakeHome = home.appendingPathComponent("stop-during-handshake")
        try FileManager.default.createDirectory(at: handshakeHome, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try "startup-hang".write(to: handshakeHome.appendingPathComponent("fault"), atomically: true, encoding: .utf8)
        let handshaking = ReferenceHelperSupervisor(bundle: bundle, home: handshakeHome,
                                                   testFault: true, startupTimeout: .seconds(30),
                                                   launcher: AppProcessComposition.makeLauncher())
        let handshake = Task { try await handshaking.start() }
        while handshaking.processIdentifier == nil { await Task.yield() }
        let handshakePID = handshaking.processIdentifier!
        await handshaking.stop()
        do {
            try await handshake.value
            throw CocoaError(.coderInvalidValue)
        } catch is CancellationError {
        } catch is ReferenceHelperSupervisor.Failure {}
        try require(handshaking.processIdentifier == nil && kill(handshakePID, 0) != 0 && errno == ESRCH,
                    "Stop reaps a published child while its startup handshake is suspended")
    }
}

@MainActor
private final class ReferenceStartupBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    private(set) var cancelled = false

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation {
                continuation = $0
                entered = true
            }
        } onCancel: {
            Task { @MainActor in self.cancelled = true }
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
#endif
