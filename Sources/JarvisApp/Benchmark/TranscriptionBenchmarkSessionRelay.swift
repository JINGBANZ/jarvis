import Foundation
import JarvisCore

/// Atomically switches one capture stream between benchmark repetitions without rebuilding the tap.
/// `@unchecked Sendable`: `lock` guards both mutable callback references and they are copied before
/// invocation, so client code never runs while the relay is locked.
final class TranscriptionBenchmarkSessionRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var session: (any TranscriptionSession)?
    private var onCapture: (@Sendable (UInt64, Int) -> Void)?

    func install(
        _ session: (any TranscriptionSession)?,
        onCapture: (@Sendable (UInt64, Int) -> Void)? = nil
    ) {
        lock.lock()
        self.session = session
        self.onCapture = onCapture
        lock.unlock()
    }

    func recordCapture(sequence: UInt64, samples: Int, at timestamp: TimeInterval) {
        lock.lock(); let session = session; let onCapture = onCapture; lock.unlock()
        onCapture?(sequence, samples)
        session?.recordCapturedAudio(
            sequenceNumber: sequence,
            sampleCount: samples,
            capturedAt: timestamp)
    }

    func send(_ data: Data, sequence: UInt64, at timestamp: TimeInterval) {
        lock.lock(); let session = session; lock.unlock()
        session?.sendAudio(data, sequenceNumber: sequence, capturedAt: timestamp)
    }

    func recordSpeech(_ event: LocalSpeechEvent, through sequence: UInt64) {
        lock.lock(); let session = session; lock.unlock()
        session?.recordLocalSpeechEvent(event, throughSequenceNumber: sequence)
    }
}
