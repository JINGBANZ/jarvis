import Foundation
import JarvisCore

/// `@unchecked Sendable`: every mutable observation array and terminal state is guarded by `lock`.
final class TranscriptionBenchmarkEventRecorder: @unchecked Sendable {
    struct Snapshot: Sendable {
        let events: [TranscriptionDiagnosticEvent]
        let captureObservations: [TranscriptionBenchmark.CaptureObservation]
        let states: [TranscriptionConnectionState]
        let terminalFailure: TranscriptionFailureReason?
    }

    enum Failure: Error, CustomStringConvertible {
        case timedOut(String)
        case terminal(TranscriptionFailureReason)
        case aborted

        var description: String {
            switch self {
            case .timedOut(let boundary): "Timed out waiting for \(boundary)"
            case .terminal(let reason): "Transcription failed: \(reason.activityDescription)"
            case .aborted: "Reconnect benchmark aborted by the operator"
            }
        }
    }

    private let lock = NSLock()
    private let abortMarker: URL?
    private var events: [TranscriptionDiagnosticEvent] = []
    private var captureObservations: [TranscriptionBenchmark.CaptureObservation] = []
    private var states: [TranscriptionConnectionState] = []
    private var terminalFailure: TranscriptionFailureReason?

    init(abortMarker: URL? = nil) {
        self.abortMarker = abortMarker
    }

    func record(_ event: TranscriptionDiagnosticEvent) {
        lock.lock(); events.append(event); lock.unlock()
    }

    func record(_ state: TranscriptionConnectionState) {
        lock.lock(); states.append(state); lock.unlock()
    }

    func recordCapture(sequence: UInt64, samples: Int) {
        lock.lock()
        captureObservations.append(.init(
            sequenceNumber: sequence, sampleCount: samples))
        lock.unlock()
    }

    func record(_ failure: TranscriptionFailureReason) {
        lock.lock(); terminalFailure = failure; lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(
            events: events,
            captureObservations: captureObservations,
            states: states,
            terminalFailure: terminalFailure)
    }

    func waitForReady(
        minimumGeneration: Int = 0,
        timeout: TimeInterval
    ) async throws -> TranscriptionDiagnosticEvent {
        try await wait(timeout: timeout, boundary: "transcription readiness") { snapshot in
            snapshot.events.first {
                $0.kind == .ready && $0.generation >= minimumGeneration
            }
        }
    }

    func waitForReconnect(timeout: TimeInterval) async throws {
        _ = try await wait(timeout: timeout, boundary: "the observed network outage") { snapshot in
            snapshot.states.contains {
                if case .reconnecting = $0 { return true }
                return false
            } ? true : nil
        } as Bool
    }

    func waitForFinals(count: Int, timeout: TimeInterval) async throws {
        _ = try await wait(timeout: timeout, boundary: "\(count) finalized transcript(s)") { snapshot in
            snapshot.events.count(where: { $0.kind == .finalized }) >= count ? true : nil
        } as Bool
    }

    func waitForRecognizedReconnectPhrases(
        _ phraseIDs: [String],
        afterGeneration generation: Int,
        timeout: TimeInterval
    ) async throws {
        let expected = Set(phraseIDs)
        _ = try await wait(
            timeout: timeout,
            boundary: "all expected reconnect phrases"
        ) { snapshot in
            let recognized = Set(TranscriptionBenchmark.recognizedReconnectPhraseIDs(
                phraseIDs,
                in: snapshot.events,
                afterGeneration: generation))
            return recognized.isSuperset(of: expected) ? true : nil
        } as Bool
    }

    private func wait<Value: Sendable>(
        timeout: TimeInterval,
        boundary: String,
        predicate: (Snapshot) -> Value?
    ) async throws -> Value {
        let deadline = Date().timeIntervalSince1970 + timeout
        while Date().timeIntervalSince1970 < deadline {
            try Task.checkCancellation()
            if let abortMarker,
               FileManager.default.fileExists(atPath: abortMarker.path) {
                throw Failure.aborted
            }
            let current = snapshot()
            if let terminalFailure = current.terminalFailure {
                throw Failure.terminal(terminalFailure)
            }
            if let value = predicate(current) { return value }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure.timedOut(boundary)
    }
}
