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
        let setupFinished = SetupCompletionFlag()
        let operation = Task {
            try await TranscriptionBenchmarkAbortMonitor.run(
                marker: marker,
                pollInterval: .milliseconds(5)
            ) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        setupFinished.set()
                        continuation.resume(returning: "finished")
                    }
                }
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        try Data().write(to: marker)
        do {
            _ = try await operation.value
            Issue.record("expected the abort marker to win the setup race")
        } catch TranscriptionBenchmarkAbortMonitor.Failure.aborted {
            // Ordering, not wall clock: "did not wait for the operation" is exactly "returned while
            // the operation was still outstanding". A loaded machine can delay this return by
            // hundreds of milliseconds with the monitor never having waited on anything, which an
            // elapsed-time budget misreads as a regression.
            #expect(!setupFinished.isSet)
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

/// `@unchecked Sendable` is safe because `lock` guards `completed`.
private final class SetupCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    var isSet: Bool { lock.withLock { completed } }
    func set() { lock.withLock { completed = true } }
}
