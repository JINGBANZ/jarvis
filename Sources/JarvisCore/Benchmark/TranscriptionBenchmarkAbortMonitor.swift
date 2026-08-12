import Foundation

/// Races a potentially non-cooperative benchmark setup operation against the command's abort
/// marker. The operation runs in an unstructured task intentionally: structured task groups wait
/// for cancelled children, which would let a model download keep Ctrl-C blocked until it returned.
public enum TranscriptionBenchmarkAbortMonitor {
    public enum Failure: Error, Equatable, Sendable {
        case aborted
    }

    public static func run<Value: Sendable>(
        marker: URL,
        pollInterval: Duration = .milliseconds(50),
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        guard !FileManager.default.fileExists(atPath: marker.path) else {
            throw Failure.aborted
        }
        let results = AsyncThrowingStream<Value, any Error> { continuation in
            let operationTask = Task {
                do {
                    continuation.yield(try await operation())
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let abortTask = Task {
                while !Task.isCancelled {
                    if FileManager.default.fileExists(atPath: marker.path) {
                        continuation.finish(throwing: Failure.aborted)
                        return
                    }
                    do {
                        try await Task.sleep(for: pollInterval)
                    } catch {
                        return
                    }
                }
            }
            continuation.onTermination = { @Sendable _ in
                operationTask.cancel()
                abortTask.cancel()
            }
        }
        var iterator = results.makeAsyncIterator()
        guard let result = try await iterator.next() else {
            try Task.checkCancellation()
            throw CancellationError()
        }
        return result
    }
}
