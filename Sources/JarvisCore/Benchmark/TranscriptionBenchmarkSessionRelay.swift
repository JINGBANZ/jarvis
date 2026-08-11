import Foundation

/// Atomically switches one capture stream between benchmark repetitions without rebuilding the tap.
/// Enqueued chunks and target installations share one serial queue, so every chunk submitted before
/// a repetition switch reaches the old target before that target is stopped. `@unchecked Sendable`:
/// `lock` guards both mutable callback references and they are copied before invocation, so client
/// code never runs while the relay is locked.
public final class TranscriptionBenchmarkSessionRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let deliveryQueue = DispatchQueue(
        label: "jarvis.benchmark.system-audio.delivery",
        qos: .userInitiated)
    private var session: (any TranscriptionSession)?
    private var onCapture: (@Sendable (UInt64, Int) -> Void)?

    public init() {}

    public func install(
        _ session: (any TranscriptionSession)?,
        onCapture: (@Sendable (UInt64, Int) -> Void)? = nil
    ) {
        deliveryQueue.sync {
            lock.lock()
            self.session = session
            self.onCapture = onCapture
            lock.unlock()
        }
    }

    public func enqueue(
        _ data: Data,
        sequence: UInt64,
        samples: Int,
        capturedAt: TimeInterval,
        speechEvents: [LocalSpeechEvent]
    ) {
        deliveryQueue.async { [self] in
            deliver(
                data,
                sequence: sequence,
                samples: samples,
                capturedAt: capturedAt,
                speechEvents: speechEvents)
        }
    }

    public func deliver(
        _ data: Data,
        sequence: UInt64,
        samples: Int,
        capturedAt: TimeInterval,
        speechEvents: [LocalSpeechEvent]
    ) {
        // One lock snapshot keeps continuity evidence, PCM, and speech edges on the same session
        // even when the runner installs the next repetition concurrently.
        lock.lock(); let session = session; let onCapture = onCapture; lock.unlock()
        onCapture?(sequence, samples)
        session?.recordCapturedAudio(
            sequenceNumber: sequence,
            sampleCount: samples,
            capturedAt: capturedAt)
        session?.sendAudio(data, sequenceNumber: sequence, capturedAt: capturedAt)
        for event in speechEvents {
            session?.recordLocalSpeechEvent(event, throughSequenceNumber: sequence)
        }
    }
}
