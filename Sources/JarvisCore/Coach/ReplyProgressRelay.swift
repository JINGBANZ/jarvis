import Foundation

/// The runner's seam between the transport's reading task and the overlay: one ordered channel per
/// request and one main-actor consumer, so an older snapshot never paints after a newer one, with
/// paints paced to one per display frame. Each snapshot is the whole state, so keeping only the
/// newest while the consumer is busy loses nothing. See wiki/architecture.md#latency.
/// @unchecked Sendable: `lock` guards the request state the sink and the runner share.
final class ReplyProgressRelay: @unchecked Sendable {
    private static let frame: Duration = .milliseconds(16)

    private struct Request {
        let started: Date
        let continuation: AsyncStream<BrainReplyProgress>.Continuation
        let consumer: Task<Void, Never>
        var last: BrainReplyProgress?
    }

    private let overlay: OverlayRendering
    private let lock = NSLock()
    private var request: Request?

    init(overlay: OverlayRendering) {
        self.overlay = overlay
    }

    /// The conversation's sink for the whole attempt; it feeds whichever request is open.
    var sink: ToolCallProgressSink {
        { delta in self.receive(delta) }
    }

    func beginRequest() {
        let (stream, continuation) = AsyncStream.makeStream(
            of: BrainReplyProgress.self, bufferingPolicy: .bufferingNewest(1))
        let overlay = overlay
        let consumer = Task { @MainActor in
            var lastPaint: ContinuousClock.Instant?
            for await snapshot in stream {
                if let lastPaint, lastPaint.duration(to: .now) < Self.frame {
                    try? await Task.sleep(for: Self.frame - lastPaint.duration(to: .now))
                }
                overlay.showReplyProgress(snapshot)
                lastPaint = .now
            }
        }
        lock.withLock {
            request = Request(started: Date(), continuation: continuation, consumer: consumer, last: nil)
        }
    }

    /// Closes the channel and waits for its consumer, so whatever the runner shows next is ordered
    /// after every snapshot. Returns the furthest snapshot the request reached.
    func endRequest() async -> BrainReplyProgress? {
        let ended = lock.withLock { () -> Request? in
            defer { request = nil }
            return request
        }
        guard let ended else { return nil }
        ended.continuation.finish()
        await ended.consumer.value
        return ended.last
    }

    /// Only the reply's first `speak` call is shown; a parallel or later call never reaches the overlay.
    private func receive(_ delta: ToolCallDelta) -> [String] {
        guard delta.index == 0, delta.name == speakToolName,
              let snapshot = SpeakArgumentsScanner.progress(in: delta.arguments) else { return [] }
        let (phases, firstTextMs) = lock.withLock { () -> ([String], Int?) in
            guard var current = request, snapshot != current.last else { return ([], nil) }
            var phases: [String] = []
            var firstTextMs: Int?
            if snapshot.hasText, current.last?.hasText != true {
                phases.append("first_speak_text_ms")
                firstTextMs = Int(Date().timeIntervalSince(current.started) * 1000)
            }
            if snapshot.linesComplete, current.last?.linesComplete != true {
                phases.append("speak_lines_ms")
            }
            current.last = snapshot
            request = current
            if snapshot.hasText { current.continuation.yield(snapshot) }
            return (phases, firstTextMs)
        }
        if let firstTextMs { jlog("💬 first text +\(firstTextMs)ms") }
        return phases
    }
}
