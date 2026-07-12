import Foundation

/// The session's conversation memory, CLIENT-managed: `CoachDriver` commits each finished turn here
/// and rebuilds every request as `[system] + snapshot() + <this turn>`. Owning the memory (instead of
/// a server-side conversation object) is what lets the harness keep it small: old screenshots are
/// stubbed, `stay_silent` turns leave no trace, and once the estimate passes the compaction threshold
/// the oldest span is replaced with a short summary (see `CoachDriver.compactIfNeeded`).
///
/// Growth is strictly append-only between compactions — the message prefix stays byte-identical
/// across requests, which is exactly what OpenAI's prompt cache needs to keep hitting.
///
/// `@unchecked Sendable`: all mutable state is guarded by `lock`.
public final class CoachHistory: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [ChatMessage] = []

    /// How many screenshots stay in history as pixels; older ones become one-line text stubs
    /// (observation masking). A screenshot is ~1–2k tokens re-billed on every later request, and a
    /// stale one rarely helps — the model can always capture a fresh look.
    private let maxImagesRetained = 1
    static let imageStub = "[an earlier screenshot was here — no longer available; call capture_screen for a fresh look]"
    /// Replaces a stale standalone OCR message (the manual-hint path's `.user` sidecar). Tool-result
    /// OCR is instead truncated back to `CoachDriver.captureResultBase`, keeping the call linkage.
    static let ocrStub = "[earlier on-screen text was here — no longer available; call capture_screen for a fresh look]"

    public init() {}

    /// The full memory, oldest first. Callers prepend the system prompt and append the new turn.
    public func snapshot() -> [ChatMessage] {
        lock.lock(); defer { lock.unlock() }
        return messages
    }

    /// Commit a finished turn's messages (the user delta, and any capture/speak calls with their
    /// results). Callers must NOT pass `stay_silent` traces — silence needs no memory. Any screenshot
    /// beyond the newest `maxImagesRetained` is replaced with a text stub.
    public func commit(_ turn: [ChatMessage]) {
        guard !turn.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        messages.append(contentsOf: turn)

        let imageIndices = messages.indices.filter { messages[$0].imageBase64JPEG != nil }
        let retained = Set(imageIndices.suffix(maxImagesRetained))

        // Mask the OCR sidecar of every stale observation alongside its screenshot: the recognized
        // text (often hundreds of tokens of dense code) is re-billed on every later request just like
        // a stale image would be. OCR sits immediately next to its screenshot — before it on the
        // capture_screen tool-result path, after it on the manual-hint `.user` path — so an OCR
        // message is stale exactly when neither neighbor is a still-retained image.
        for index in messages.indices where messages[index].text?.contains(CoachDriver.recognizedTextMarker) == true {
            let accompaniesRetainedImage = retained.contains(index - 1) || retained.contains(index + 1)
            if !accompaniesRetainedImage { messages[index] = Self.neutralizeOCR(messages[index]) }
        }

        for index in imageIndices.dropLast(maxImagesRetained) {
            messages[index] = .user(Self.imageStub)
        }
    }

    /// Strip the OCR block from a stale observation. A tool result keeps its role + `toolCallId` (the
    /// wire format requires the tool message to stay paired with its assistant call) and drops to the
    /// marker-free base line; a standalone `.user` OCR message becomes a tiny stub.
    private static func neutralizeOCR(_ m: ChatMessage) -> ChatMessage {
        m.role == .tool
            ? .init(role: .tool, text: CoachDriver.captureResultBase, toolCallId: m.toolCallId)
            : .user(ocrStub)
    }

    /// Rough size of the memory in tokens (chars/4 for text, a flat estimate per screenshot) — used
    /// only to decide WHEN to compact, so precision doesn't matter.
    public var estimatedTokens: Int {
        lock.lock(); defer { lock.unlock() }
        return Self.estimate(messages)
    }

    private static func estimate(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { total, m in
            var t = total + ((m.text?.count ?? 0) / 4)
            if m.imageBase64JPEG != nil { t += 1_500 }
            if let calls = m.toolCalls { t += calls.reduce(0) { $0 + ($1.argumentsJSON.count / 4) + 8 } }
            return t
        }
    }

    /// The oldest span to summarize: the longest message prefix holding roughly `fraction` of the
    /// estimated tokens — clamped to at least one message (a single oversized message must still be
    /// compactable) and never the whole history (the newest turn stays verbatim). Returns nil only
    /// when there's a single message or none, i.e. nothing meaningful to split.
    public func compactionPrefix(fraction: Double = 0.6) -> (messages: [ChatMessage], count: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard messages.count > 1 else { return nil }
        let budget = Int(Double(Self.estimate(messages)) * fraction)
        var used = 0, count = 0
        for m in messages {
            let cost = Self.estimate([m])
            if used + cost > budget { break }
            used += cost; count += 1
        }
        count = min(max(count, 1), messages.count - 1)
        return (Array(messages.prefix(count)), count)
    }

    /// Replace the oldest `prefixCount` messages with a single summary message. Tolerates the tail
    /// having grown while the summary was being written — only the exact prefix handed out by
    /// `compactionPrefix` is replaced. One deliberate prompt-cache miss; cache-hot again afterwards.
    public func compact(prefixCount: Int, summary: String) {
        lock.lock(); defer { lock.unlock() }
        guard prefixCount > 0, prefixCount <= messages.count else { return }
        let head = ChatMessage.user("[session so far, condensed — earlier turns were summarized]\n\(summary)")
        messages.replaceSubrange(0..<prefixCount, with: [head])
    }
}
