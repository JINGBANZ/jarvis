#if JARVIS_LIVE_E2E
import Foundation
import JarvisCore

/// @unchecked: lock protects all reply state; clock synchronizes itself.
final class ReplayOverlay: OverlayRendering, @unchecked Sendable {
    private let lock = NSLock()
    private let clock: ReplayClock
    private var replies: [VisibleEvaluationReply] = []
    private var open: Int?
    init(clock: ReplayClock) { self.clock = clock }
    @MainActor var acceptsDetail: Bool { true }
    var visible: [VisibleEvaluationReply] { lock.withLock { replies } }
    func reset() { lock.withLock { replies = []; open = nil } }
    @MainActor func showReplyProgress(_ progress: BrainReplyProgress?) {
        lock.withLock {
            guard let progress else {
                if let open { replies[open].withdrawn = true }
                open = nil
                return
            }
            guard progress.hasText else { return }
            update(hint: progress.hint, detail: progress.detailMarkdown)
        }
    }
    private func update(hint: String, detail: String?) {
        if open == nil {
            replies.append(.init(hint: hint, detail: detail, at: clock.now()))
            open = replies.count - 1
        }
        if let open {
            replies[open].hint = hint; replies[open].detail = detail
            replies[open].snapshots.append(hint + "\n" + (detail ?? ""))
        }
    }
    @MainActor func deliver(_ hint: String, detail: ReplyDetail?) -> ReplyDetail? {
        lock.withLock {
            update(hint: hint, detail: detail?.deliveredMarkdown)
            open = nil
        }
        return detail
    }
    func render(_ hint: String) {
        lock.withLock { update(hint: hint, detail: nil); open = nil }
    }
}

#endif
