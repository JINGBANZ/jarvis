import Foundation
import Testing
@testable import JarvisCore

@Suite("Transcription benchmark abort monitor")
struct TranscriptionBenchmarkAbortMonitorTests {
    @Test("an abort does not wait for a non-cooperative setup operation")
    func abortsNonCooperativeOperation() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("abort")
        // The operation ignores the cancellation the monitor sends it and stays outstanding until
        // this test releases it, which is what makes the claim decidable by ordering alone. Racing
        // a timed operation instead left the assertion measuring how promptly a loaded machine
        // happened to schedule the abort rather than whether the abort waited for anything.
        let setup = ManualSetupOperation()
        defer { setup.release() }
        let monitored = Task {
            try await TranscriptionBenchmarkAbortMonitor.run(
                marker: marker,
                pollInterval: .milliseconds(5)
            ) {
                await setup.run()
            }
        }

        await setup.waitUntilStarted()
        try Data().write(to: marker)
        do {
            _ = try await monitored.value
            Issue.record("expected the abort marker to win the setup race")
        } catch TranscriptionBenchmarkAbortMonitor.Failure.aborted {
            #expect(!setup.hasFinished)
        } catch {
            Issue.record("expected an aborted failure, got \(error)")
        }
    }

    @Test("a completed setup operation returns its value")
    func returnsCompletedValue() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }

        let value = try await TranscriptionBenchmarkAbortMonitor.run(
            marker: directory.appendingPathComponent("abort")
        ) {
            "prepared"
        }

        #expect(value == "prepared")
    }
}

/// Setup work that begins when the monitor runs it and finishes only when the test releases it,
/// standing in for a non-cooperative operation such as a model download that ignores cancellation.
/// `@unchecked Sendable` is safe because `lock` guards every stored property.
private final class ManualSetupOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var didStart = false
    private var didRelease = false
    private var didFinish = false

    var hasFinished: Bool { lock.withLock { didFinish } }

    func run() async -> String {
        reportStarted()
        await waitForRelease()
        lock.withLock { didFinish = true }
        return "finished"
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyStarted: Bool = lock.withLock {
                guard didStart else {
                    startWaiter = continuation
                    return false
                }
                return true
            }
            if alreadyStarted { continuation.resume() }
        }
    }

    func release() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            didRelease = true
            let waiting = releaseWaiter
            releaseWaiter = nil
            return waiting
        }
        waiter?.resume()
    }

    private func reportStarted() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            didStart = true
            let waiting = startWaiter
            startWaiter = nil
            return waiting
        }
        waiter?.resume()
    }

    private func waitForRelease() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyReleased: Bool = lock.withLock {
                guard didRelease else {
                    releaseWaiter = continuation
                    return false
                }
                return true
            }
            if alreadyReleased { continuation.resume() }
        }
    }
}
