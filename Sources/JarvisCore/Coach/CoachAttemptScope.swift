import Foundation

/// `@unchecked Sendable`: `lock` guards output ownership and the attempt's retained operations.
final class CoachAttemptScope: @unchecked Sendable {
    private enum Phase { case replaceable, streaming, completed, cancelled }
    private let lock = NSLock()
    private var phase: Phase = .replaceable
    private var operations: [Task<Void, Never>] = []
    private var conversation: (any BrainConversation)?
    private var closed = false

    var isCancelled: Bool { lock.withLock { phase == .cancelled } }

    func replace() -> Bool {
        lock.withLock {
            guard phase == .replaceable else { return false }
            phase = .cancelled
            return true
        }
    }

    func cancel() {
        lock.withLock {
            if phase != .completed { phase = .cancelled }
        }
    }

    /// The first visible paint and a replacement press arbitrate under the same lock.
    func acceptOutput() -> Bool {
        lock.withLock {
            guard phase == .replaceable || phase == .streaming else { return false }
            phase = .streaming
            return true
        }
    }

    func commit(_ body: () -> Void) -> Bool {
        lock.withLock {
            guard phase != .cancelled, phase != .completed else { return false }
            phase = .completed
            body()
            return true
        }
    }

    func retain(_ conversation: any BrainConversation) {
        lock.withLock { self.conversation = conversation }
    }

    /// Cancellation releases the logical runner; the operation remains owned until cleanup drains.
    func run<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let (stream, continuation) = AsyncThrowingStream<Value, Error>.makeStream()
        let task = lock.withLock { () -> Task<Void, Never>? in
            guard !closed, phase != .cancelled else { return nil }
            let task = Task {
                do {
                    try Task.checkCancellation()
                    continuation.yield(try await operation())
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            operations.append(task)
            return task
        }
        guard let task else { throw CancellationError() }
        return try await withTaskCancellationHandler {
            var iterator = stream.makeAsyncIterator()
            guard let value = try await iterator.next() else { throw CancellationError() }
            try Task.checkCancellation()
            guard !isCancelled else { throw CancellationError() }
            return value
        } onCancel: {
            continuation.finish(throwing: CancellationError())
            task.cancel()
        }
    }

    func finish() -> Task<Void, Never> {
        let pending = lock.withLock {
            closed = true
            return operations
        }
        return Task {
            await withTaskCancellationHandler {
                for operation in pending { await operation.value }
                // Creation may succeed after cancellation; its conversation still needs exactly one finish.
                let conversation = lock.withLock { self.conversation }
                await conversation?.finish()
            } onCancel: {
                pending.forEach { $0.cancel() }
            }
        }
    }
}
