import Foundation

/// The session's conversation memory, CLIENT-managed: `CoachDriver` commits each finished turn here
/// and rebuilds every request as `[system] + snapshot() + <this turn>`. Owning the memory (instead of
/// a server-side conversation object) is what lets the harness keep it small: screenshots are stubbed
/// at commit, `stay_silent` turns leave no trace, and once the estimate passes the compaction threshold
/// the oldest span is replaced with a short summary (see `CoachDriver.compactIfNeeded`).
///
/// Growth is strictly append-only between compactions — the message prefix stays byte-identical
/// across requests, which is exactly what OpenAI's prompt cache needs to keep hitting.
///
/// `@unchecked Sendable`: all mutable state is guarded by `lock`.
public final class CoachHistory: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [ChatMessage] = []
    /// Bumped whenever committed messages are rewritten in place rather than merely appended to.
    /// Compaction reads history, then writes a summary of it much later from another task; growth in
    /// the tail is safe for that, but an in-place OCR collapse is not, because the summary would
    /// reintroduce the very screen text the collapse just retired.
    private var rewriteRevision: UInt = 0
    /// Session-elapsed seconds at which the one still-verbatim OCR block was committed, or nil when
    /// history holds none. Stored rather than read back out of the message text: the [mm:ss] stamp in
    /// a capture result is written for the model, and parsing our own prompt copy would make the
    /// wording of a catalog string load-bearing.
    private var liveScreenTextElapsed: TimeInterval?

    public init() {}

    /// The full memory, oldest first. Callers prepend the system prompt and append the new turn.
    public func snapshot() -> [ChatMessage] {
        lock.lock(); defer { lock.unlock() }
        return messages
    }

    /// Commit a finished turn's messages (the user delta, and any capture/speak calls with their
    /// results). Callers must NOT pass `stay_silent` traces — silence needs no memory. Two kinds of
    /// message are rewritten at commit:
    /// - **Screenshots** are replaced with a text stub (observation masking). The capture's OCR text
    ///   — what the model actually reads — rides in the tool-result message and stays verbatim; the
    ///   pixels are ~1–2k tokens re-billed on every later request, and the model can always capture
    ///   a fresh look. When the turn carries a NEW OCR block, every earlier OCR dump — committed
    ///   history and any older capture within the same turn — collapses to a one-line stub:
    ///   near-identical screens re-billed forever, and a session-audit caught the model
    ///   "correcting" code the user had already fixed by reading a stale dump. Unlike the two
    ///   tail-local rewrites above, this one re-diverges the prompt-cache prefix at the oldest
    ///   collapsed block. That is deliberate: a bounded one-request re-read per capture buys back
    ///   ~1k stale tokens per dump on every later request plus the stale-context failure mode above.
    ///   A local provider receives the complete committed history once at the start of an attempt;
    ///   any capture continuation on that attempt carries only incremental input.
    /// - **Raw passthrough items** (a response's verbatim `output` array, replayed whole within the
    ///   turn's tool loop) are CONVERTED, not kept: the `function_call` items survive as one
    ///   synthetic id-less call message — so the committed `function_call_output` never orphans —
    ///   and `reasoning` (and any other) items are dropped. OpenAI only needs reasoning WITHIN the
    ///   turn's tool loop; across turns a new user message follows and stale reasoning is ignored,
    ///   retaining it would re-bill every later request, and a brain-model switch invalidates
    ///   reasoning items outright. The id-less call + output pair is the long-proven history shape.
    /// Both rewrites cost one prompt-cache divergence at the tail of the just-finished turn — far
    /// cheaper than re-billing the content on every request for the rest of the session.
    public func commit(_ turn: [ChatMessage], at sessionElapsed: TimeInterval) {
        guard !turn.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var turn = turn
        let ocrHeader = JarvisPrompts.Coach.recognizedTextHeader
        if let newest = turn.lastIndex(where: { $0.text?.contains(ocrHeader) == true }) {
            messages = messages.map(Self.collapsingSupersededOCR)
            rewriteRevision &+= 1
            // One tool loop may capture more than once — only the turn's newest OCR stays verbatim.
            for i in turn.indices where i < newest { turn[i] = Self.collapsingSupersededOCR(turn[i]) }
            // The shot itself was taken a few seconds before this commit, well inside the staleness
            // window, so the commit time stands in for the capture time rather than being threaded
            // separately from each of the two capture sites.
            liveScreenTextElapsed = sessionElapsed
        }
        messages.append(contentsOf: turn.compactMap { m in
            if let raw = m.rawItemsJSON { return Self.convertRawItems(raw) }
            return m.imageBase64JPEG != nil
                ? .user(JarvisPrompts.Coach.earlierImageStub)
                : m
        })
    }

    /// Retire the one still-verbatim OCR block once it is older than `olderThan`, so a screen read
    /// minutes ago stops presenting itself as the screen now. Superseding alone cannot do this: it
    /// fires only when a NEWER capture lands, so the last dump of a session — or of a stretch where
    /// the coach never looked again — persists verbatim to the end. Reported by a session audit where
    /// the coach answered a freshly asked question against the previous question's screen.
    ///
    /// Called explicitly by the attempt runner just before it snapshots, rather than folded into
    /// `snapshot()`: expiry is an in-place rewrite of committed messages, and hiding one inside a
    /// read would make a getter bump `rewriteRevision` and diverge the prompt-cache prefix. Returns
    /// whether anything was retired, and is a no-op once it has been.
    @discardableResult
    public func expireStaleScreenText(olderThan: TimeInterval, at sessionElapsed: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let landed = liveScreenTextElapsed, sessionElapsed - landed > olderThan else { return false }
        messages = messages.map { Self.collapsingOCR(in: $0, to: JarvisPrompts.Coach.staleRecognizedTextStub) }
        rewriteRevision &+= 1
        liveScreenTextElapsed = nil
        return true
    }

    /// Rewrite one committed message so its OCR block becomes the catalog's superseded marker.
    /// Text before the block — e.g. a successful capture result — survives.
    private static func collapsingSupersededOCR(_ m: ChatMessage) -> ChatMessage {
        collapsingOCR(in: m, to: JarvisPrompts.Coach.supersededRecognizedTextStub)
    }

    /// Replace a message's OCR block with `stub`, keeping everything before the header — the capture
    /// result's "[mm:ss] screenshot captured" line — so the retired look still says when it happened.
    private static func collapsingOCR(in m: ChatMessage, to stub: String) -> ChatMessage {
        guard let text = m.text,
              let header = text.range(of: JarvisPrompts.Coach.recognizedTextHeader)
        else { return m }
        return ChatMessage(
            role: m.role,
            text: String(text[..<header.lowerBound]) + stub,
            toolCallId: m.toolCallId
        )
    }

    /// The commit-time conversion of a verbatim passthrough message: keep its `function_call` items
    /// as one synthetic id-less `assistantToolCalls` message, drop everything else. Nil when the
    /// items carried no function call — nothing a later turn can use.
    private static func convertRawItems(_ itemsJSON: [String]) -> ChatMessage? {
        let calls = itemsJSON.compactMap { itemJSON -> RawToolCall? in
            guard let item = (try? JSONSerialization.jsonObject(with: Data(itemJSON.utf8))) as? [String: Any],
                  item["type"] as? String == "function_call",
                  let callId = item["call_id"] as? String,
                  let name = item["name"] as? String else { return nil }
            return RawToolCall(id: callId, name: name,
                               argumentsJSON: item["arguments"] as? String ?? "{}")
        }
        return calls.isEmpty ? nil : .assistantToolCalls(calls)
    }

    /// Rough size of the memory in tokens — used only to decide WHEN to compact. ASCII text uses the
    /// common chars/4 heuristic; every non-ASCII scalar counts as one so Chinese and other scripts do
    /// not wait several times too long. No image term: screenshots are stubbed to text at commit.
    public var estimatedTokens: Int {
        lock.lock(); defer { lock.unlock() }
        return Self.estimate(messages)
    }

    private static func estimate(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { total, m in
            var t = total + (m.text.map(estimatedTextTokens) ?? 0)
            if let calls = m.toolCalls {
                t += calls.reduce(0) { $0 + estimatedTextTokens($1.argumentsJSON) + 8 }
            }
            return t
        }
    }

    private static func estimatedTextTokens(_ text: String) -> Int {
        var asciiCount = 0
        var nonASCIICount = 0
        for scalar in text.unicodeScalars {
            if scalar.value < 128 {
                asciiCount += 1
            } else {
                nonASCIICount += 1
            }
        }
        return ((asciiCount + 3) / 4) + nonASCIICount
    }

    /// The oldest span to summarize: the longest message prefix holding roughly `fraction` of the
    /// estimated tokens — clamped to at least one message (a single oversized message must still be
    /// compactable) and never the whole history (the newest turn stays verbatim). Returns nil only
    /// when there's a single message or none, i.e. nothing meaningful to split.
    public func compactionPrefix(fraction: Double = 0.6)
        -> (messages: [ChatMessage], count: Int, revision: UInt)? {
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
        return (Array(messages.prefix(count)), count, rewriteRevision)
    }

    /// Replace the oldest `prefixCount` messages with a single summary message. Tolerates the tail
    /// having grown while the summary was being written — only the exact prefix handed out by
    /// `compactionPrefix` is replaced. One deliberate prompt-cache miss; cache-hot again afterwards.
    ///
    /// Rejects a summary written against a since-rewritten prefix, reporting whether it applied. The
    /// summary is produced off the attempt path, so a capture committed meanwhile can collapse OCR
    /// inside that prefix; applying the older summary would put the retired screen text straight back
    /// into history and let a later tip cite code the user has already changed. Dropping it is safe —
    /// history is unchanged and the next completed attempt compacts again from a fresh prefix.
    @discardableResult
    public func compact(prefixCount: Int, summary: String, revision: UInt) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard prefixCount > 0, prefixCount <= messages.count else { return false }
        guard revision == rewriteRevision else { return false }
        let head = ChatMessage.user(JarvisPrompts.Coach.condensedHistory(summary))
        messages.replaceSubrange(0..<prefixCount, with: [head])
        return true
    }
}
