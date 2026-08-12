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
        let operation = Task {
            try await TranscriptionBenchmarkAbortMonitor.run(
                marker: marker,
                pollInterval: .milliseconds(5)
            ) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        continuation.resume(returning: "finished")
                    }
                }
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        let abortStartedAt = ContinuousClock.now
        try Data().write(to: marker)
        do {
            _ = try await operation.value
            Issue.record("expected the abort marker to win the setup race")
        } catch TranscriptionBenchmarkAbortMonitor.Failure.aborted {
            let elapsed = abortStartedAt.duration(to: .now)
            #expect(elapsed < .milliseconds(500))
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
