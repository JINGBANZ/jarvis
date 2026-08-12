import Foundation

/// `@unchecked Sendable`: every mutable observation array and terminal state is guarded by `lock`.
public final class TranscriptionBenchmarkEventRecorder: TranscriptionBenchmarkObserving,
    @unchecked Sendable {
    public struct Snapshot: Sendable {
        public let events: [TranscriptionBenchmarkEvent]
        public let captureObservations: [TranscriptionBenchmark.CaptureObservation]
        public let states: [TranscriptionConnectionState]
        public let terminalFailure: TranscriptionFailureReason?
    }

    public enum Failure: Error, CustomStringConvertible {
        case timedOut(String)
        case terminal(TranscriptionFailureReason)
        case aborted

        public var description: String {
            switch self {
            case .timedOut(let boundary): "Timed out waiting for \(boundary)"
            case .terminal(let reason): "Transcription failed: \(reason.activityDescription)"
            case .aborted: "Transcription benchmark aborted"
            }
        }
    }

    private let lock = NSLock()
    private let abortMarker: URL?
    private var events: [TranscriptionBenchmarkEvent] = []
    private var captureObservations: [TranscriptionBenchmark.CaptureObservation] = []
    private var states: [TranscriptionConnectionState] = []
    private var terminalFailure: TranscriptionFailureReason?

    public init(abortMarker: URL? = nil) {
        self.abortMarker = abortMarker
    }

    public func record(_ event: TranscriptionBenchmarkEvent) {
        lock.lock(); events.append(event); lock.unlock()
    }

    public func record(_ state: TranscriptionConnectionState) {
        lock.lock(); states.append(state); lock.unlock()
    }

    public func recordCapture(sequence: UInt64, samples: Int) {
        lock.lock()
        captureObservations.append(.init(
            sequenceNumber: sequence, sampleCount: samples))
        lock.unlock()
    }

    public func record(_ failure: TranscriptionFailureReason) {
        lock.lock(); terminalFailure = failure; lock.unlock()
    }

    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(
            events: events,
            captureObservations: captureObservations,
            states: states,
            terminalFailure: terminalFailure)
    }

    public func waitForReady(
        minimumGeneration: Int = 0,
        timeout: TimeInterval
    ) async throws -> TranscriptionBenchmarkEvent {
        try await wait(timeout: timeout, boundary: "transcription readiness") { snapshot in
            snapshot.events.first {
                $0.kind == .ready && $0.generation >= minimumGeneration
            }
        }
    }

    public func waitForReconnect(timeout: TimeInterval) async throws {
        _ = try await wait(
            timeout: timeout,
            boundary: "the scoped transcription transport interruption"
        ) { snapshot in
            snapshot.states.contains {
                if case .reconnecting = $0 { return true }
                return false
            } ? true : nil
        } as Bool
    }

    public func waitForFinals(count: Int, timeout: TimeInterval) async throws {
        _ = try await wait(timeout: timeout, boundary: "\(count) finalized transcript(s)") { snapshot in
            snapshot.events.count(where: { $0.kind == .finalized }) >= count ? true : nil
        } as Bool
    }

    /// Waits until at least `minimumCount` finals have arrived and no additional final has been
    /// observed for `quietPeriod`. Providers may split one fixture across multiple finalized items,
    /// so the standard benchmark cannot treat the first callback as the complete transcript.
    public func waitForFinalStreamToSettle(
        minimumCount: Int,
        quietPeriod: TimeInterval,
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().timeIntervalSince1970 + timeout
        var observedFinalCount: Int?
        var lastChangeAt: TimeInterval?
        while Date().timeIntervalSince1970 < deadline {
            try Task.checkCancellation()
            let current = try checkedSnapshot()
            let now = Date().timeIntervalSince1970
            let finalCount = current.events.count(where: { $0.kind == .finalized })
            if finalCount != observedFinalCount {
                observedFinalCount = finalCount
                lastChangeAt = now
            }
            if finalCount >= minimumCount,
               let lastChangeAt,
               now - lastChangeAt >= quietPeriod {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure.timedOut("a settled finalized transcript stream")
    }

    /// Waits for every expected phrase in one replacement generation, then keeps observing that
    /// generation until its final stream has stayed quiet. Late duplicate or unrelated finals are
    /// therefore included in the acceptance snapshot rather than hidden by an early session stop.
    public func waitForRecognizedReconnectFinalStreamToSettle(
        _ phraseIDs: [String],
        inGeneration generation: Int,
        quietPeriod: TimeInterval,
        timeout: TimeInterval
    ) async throws {
        let expected = Set(phraseIDs)
        let deadline = Date().timeIntervalSince1970 + timeout
        var observedFinalCount: Int?
        var lastChangeAt: TimeInterval?
        while Date().timeIntervalSince1970 < deadline {
            try Task.checkCancellation()
            let snapshot = try checkedSnapshot()
            let now = Date().timeIntervalSince1970
            let finalCount = snapshot.events.count {
                $0.kind == .finalized && $0.generation == generation
            }
            if finalCount != observedFinalCount {
                observedFinalCount = finalCount
                lastChangeAt = now
            }
            let recognized = Set(TranscriptionBenchmark.recognizedReconnectPhraseIDs(
                phraseIDs,
                in: snapshot.events,
                generation: generation))
            if recognized.isSuperset(of: expected),
               let lastChangeAt,
               now - lastChangeAt >= quietPeriod {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure.timedOut("a settled reconnect final stream containing all expected phrases")
    }

    private func wait<Value: Sendable>(
        timeout: TimeInterval,
        boundary: String,
        predicate: (Snapshot) -> Value?
    ) async throws -> Value {
        let deadline = Date().timeIntervalSince1970 + timeout
        while Date().timeIntervalSince1970 < deadline {
            try Task.checkCancellation()
            let current = try checkedSnapshot()
            if let value = predicate(current) { return value }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure.timedOut(boundary)
    }

    private func checkedSnapshot() throws -> Snapshot {
        if let abortMarker,
           FileManager.default.fileExists(atPath: abortMarker.path) {
            throw Failure.aborted
        }
        let current = snapshot()
        if let terminalFailure = current.terminalFailure {
            throw Failure.terminal(terminalFailure)
        }
        return current
    }
}
