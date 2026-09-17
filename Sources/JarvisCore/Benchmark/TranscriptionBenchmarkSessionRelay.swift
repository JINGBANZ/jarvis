import Foundation

/// Chunks and installs share one serial queue, so a chunk queued before a switch reaches the old
/// target before it stops. `@unchecked Sendable`: `lock` guards both callback references, which are
/// copied before invocation so client code never runs under the lock.
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
        // One snapshot keeps evidence, PCM, and speech edges on the same session during an install.
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
